use aery::prelude::*;
use bevy_ecs::prelude::*;
use bvh_arena::{Bvh, VolumeHandle};
use digilogic_core::components::{Child, Circuit, Net};
use digilogic_core::transform::{AbsoluteBoundingBox, BoundingBox, Vec2};
use digilogic_core::{fixed, Fixed, HashMap};
use digilogic_routing::{RoutingComplete, VertexKind, Vertices};

#[allow(missing_debug_implementations)]
#[derive(Resource, Default)]
pub struct SpatialIndex {
    index: Bvh<Entity, BoundingBox>,
    handles: HashMap<Entity, Vec<VolumeHandle>>,
}

impl SpatialIndex {
    pub fn remove(&mut self, entity: Entity) {
        if let Some(handles) = self.handles.remove(&entity) {
            for handle in handles {
                self.index.remove(handle);
            }
        }
    }

    /// Update the spatial index for the given entity with a single bounding box.
    /// Any existing bounding boxes for the entity will be removed.
    pub fn update(&mut self, entity: Entity, bounds: BoundingBox) {
        self.update_all(entity, vec![bounds]);
    }

    /// Update the spatial index for the given entity with multiple bounding boxes.
    /// Any existing bounding boxes for the entity will be removed.
    pub fn update_all(&mut self, entity: Entity, bounds: Vec<BoundingBox>) {
        let handles = if let Some(handles) = self.handles.get_mut(&entity) {
            for handle in handles.iter() {
                self.index.remove(*handle);
            }
            handles.clear();
            handles
        } else {
            self.handles.insert(entity, Vec::new());
            self.handles.get_mut(&entity).unwrap()
        };
        for bound in bounds {
            let handle = self.index.insert(entity, bound);
            handles.push(handle);
        }
    }

    pub fn query(&self, bounds: BoundingBox, cb: impl FnMut(&Entity)) {
        self.index.for_each_overlaps(&bounds, cb);
    }
}

pub(crate) fn update_spatial_index(
    mut index: ResMut<SpatialIndex>,
    query: Query<(Entity, &AbsoluteBoundingBox), Changed<AbsoluteBoundingBox>>,
) {
    query.iter().for_each(|(entity, bounds)| {
        index.update(entity, **bounds);
    });
}

pub(crate) fn on_remove_bounding_box_update_spatial_index(
    trigger: Trigger<OnRemove, AbsoluteBoundingBox>,
    mut index: ResMut<SpatialIndex>,
) {
    index.remove(trigger.entity());
}

pub(crate) fn update_spatial_index_on_routing(
    mut index: ResMut<SpatialIndex>,
    mut routing_events: EventReader<RoutingComplete>,
    circuits: Query<((), Relations<Child>), With<Circuit>>,
    nets: Query<(Entity, &Vertices), With<Net>>,
) {
    for event in routing_events.read() {
        bevy_log::debug!("Updating spatial index on routing event");
        let (_, circuit_children) = circuits.get(event.circuit.0).unwrap();
        let mut boxes = Vec::new();
        circuit_children
            .join::<Child>(&nets)
            .for_each(|(net_id, vertices)| {
                let mut prev_vertex = None;
                for vertex in vertices.iter() {
                    match vertex.kind {
                        VertexKind::Normal => {
                            if let Some(prev_vertex) = prev_vertex {
                                add_bounding_box(prev_vertex, vertex.position, &mut boxes);
                            }
                            prev_vertex = Some(vertex.position);
                        }
                        VertexKind::WireStart { .. } => {
                            prev_vertex = Some(vertex.position);
                        }
                        VertexKind::WireEnd { .. } => {
                            if let Some(prev_vertex) = prev_vertex {
                                add_bounding_box(prev_vertex, vertex.position, &mut boxes);
                            }
                            prev_vertex = None;
                        }
                    }
                }

                index.update_all(net_id, boxes.clone());
                boxes.clear();
            });
    }
}

const WIRE_BBOX_THICKNESS: Fixed = fixed!(4);

fn add_bounding_box(p1: Vec2, p2: Vec2, boxes: &mut Vec<BoundingBox>) {
    if p1.x == p2.x {
        let half_extent = (p2.y - p1.y).abs() / fixed!(2);
        let center = (p1 + p2) / fixed!(2);
        boxes.push(BoundingBox::from_center_half_size(
            center,
            WIRE_BBOX_THICKNESS,
            half_extent,
        ));
    } else {
        let half_extent = (p2.x - p1.x).abs() / fixed!(2);
        let center = (p1 + p2) / fixed!(2);
        boxes.push(BoundingBox::from_center_half_size(
            center,
            half_extent,
            WIRE_BBOX_THICKNESS,
        ));
    }
}

pub(crate) fn on_remove_net_update_spatial_index(
    trigger: Trigger<OnRemove, Net>,
    mut index: ResMut<SpatialIndex>,
) {
    index.remove(trigger.entity());
}
