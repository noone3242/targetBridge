#ifndef TB_BC7_DELTA_H
#define TB_BC7_DELTA_H

#include <stddef.h>
#include <stdint.h>

#define TB_BC7_DELTA_TILE_SIZE 64u
#define TB_BC7_DELTA_MAX_RUNS 256u

struct tb_bc7_delta_run {
    uint16_t tile_x;
    uint16_t tile_y;
    uint16_t tile_count_x;
    uint16_t pixel_height;
    uint32_t data_length;
    const uint8_t *data;
};

struct tb_bc7_delta_frame {
    uint64_t sequence;
    uint64_t base_sequence;
    uint64_t checksum;
    uint32_t width;
    uint32_t height;
    uint16_t tile_size;
    uint16_t run_count;
    struct tb_bc7_delta_run runs[TB_BC7_DELTA_MAX_RUNS];
};

int tb_bc7_delta_parse(const uint8_t *payload,
                       size_t payload_len,
                       struct tb_bc7_delta_frame *frame);
int tb_bc7_delta_sequence_valid(uint64_t sequence,
                                uint64_t base_sequence,
                                uint64_t applied_sequence);

uint64_t tb_bc7_tile_checksum(const uint8_t *data,
                              uint32_t row_bytes,
                              uint32_t block_rows,
                              uint32_t tile_index);
int tb_bc7_delta_apply_to_shadow(const struct tb_bc7_delta_frame *frame,
                                 uint8_t *shadow,
                                 size_t shadow_len,
                                 uint32_t bytes_per_row,
                                 uint64_t *tile_checksums,
                                 size_t tile_count,
                                 uint64_t *checksum);

#endif
