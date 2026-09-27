#ifndef TB_NV12_TILE_RUNS_H
#define TB_NV12_TILE_RUNS_H

#include <stddef.h>
#include <stdint.h>

#define TB_NV12_TILE_RUN_FORMAT 4u
#define TB_NV12_TILE_RUN_COMPRESSION_LZ4 1u
#define TB_NV12_TILE_RUN_SIZE 64u
#define TB_NV12_TILE_RUN_MAX_RUNS 4096u
#define TB_NV12_TILE_RUN_HEADER_BYTES 32u
#define TB_NV12_TILE_RUN_DESCRIPTOR_BYTES 16u

struct tb_nv12_tile_run {
    uint16_t tile_x;
    uint16_t tile_y;
    uint16_t tile_count_x;
    uint16_t pixel_height;
    uint32_t data_offset;
    uint32_t data_length;
};

struct tb_nv12_tile_run_frame {
    uint32_t width;
    uint32_t height;
    uint32_t run_count;
    uint32_t raw_length;
    uint32_t compressed_length;
    uint64_t checksum;
    const uint8_t *compressed;
};

int tb_nv12_tile_run_parse(
    const uint8_t *payload,
    size_t payload_length,
    struct tb_nv12_tile_run_frame *frame,
    struct tb_nv12_tile_run *runs,
    size_t run_capacity);

#endif
