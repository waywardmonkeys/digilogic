/*
   Copyright 2024 Ryan "rj45" Sanche

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

#include <stdio.h>
#include <stdlib.h>

#define ASSETSYS_IMPLEMENTATION
#define STRPOOL_IMPLEMENTATION

#include "strpool.h"

#include "assetsys.h"

int main(int argc, char **argv) {
  char *buffer = 0;
  size_t length = 0;

  mz_zip_archive zip = {0};

  if (!mz_zip_writer_init_heap(&zip, 0, 0)) {
    fprintf(stderr, "Failed to initialize zip writer\n");
    return 1;
  }

  for (int i = 1; i < (argc - 1); i++) {
    char *archiveFile = strstr(argv[i], "assets");
    mz_zip_writer_add_file(
      &zip, archiveFile, argv[i], "", 0, MZ_BEST_COMPRESSION);
  }

  mz_zip_writer_finalize_heap_archive(&zip, (void **)&buffer, &length);

  FILE *fp = fopen(argv[argc - 1], "wt");

  fprintf(
    fp,
    "// This file was generated by gen.c from a zip of res/assets -- DO NOT "
    "EDIT\n\n");
  fprintf(fp, "unsigned int assets_zip_len = %td;\n", length);
  fprintf(fp, "const unsigned char assets_zip[] = {\n    ");
  for (int i = 0; i < length; i++) {
    fprintf(fp, "0x%02x,", buffer[i] & 0xff);
    if (i % 10 == 9) {
      fprintf(fp, "\n    ");
    }
  }
  fprintf(fp, "\n};\n");

  fclose(fp);
  mz_zip_writer_end(&zip);

  return 0;
}