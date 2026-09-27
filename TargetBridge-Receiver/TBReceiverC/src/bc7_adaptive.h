#ifndef TB_BC7_ADAPTIVE_H
#define TB_BC7_ADAPTIVE_H

#include "bc7_delta.h"

#include <stddef.h>
#include <stdint.h>

#define TB_BC7_ADAPTIVE_FORMAT_VERSION 1u
#define TB_BC7_ADAPTIVE_CANVAS_WIDTH 5120u
#define TB_BC7_ADAPTIVE_CANVAS_HEIGHT 2880u
#define TB_BC7_ADAPTIVE_MAX_PATCHES 256u
#define TB_BC7_ADAPTIVE_MAX_ATLAS_WIDTH 8192u
#define TB_BC7_ADAPTIVE_MAX_ATLAS_HEIGHT 8192u
#define TB_BC7_ADAPTIVE_MAX_ATLAS_BYTES (64u * 1024u * 1024u)
#define TB_BC7_ADAPTIVE_MAX_PACKET_BYTES (64u * 1024u * 1024u)

struct tb_bc7_adaptive_patch {
    uint16_t destination_x;
    uint16_t destination_y;
    uint16_t destination_width;
    uint16_t destination_height;
    uint16_t atlas_source_x;
    uint16_t atlas_source_y;
    uint16_t atlas_source_width;
    uint16_t atlas_source_height;
};

struct tb_bc7_adaptive_frame {
    uint32_t generation;
    uint64_t frame_id;
    uint64_t capture_timestamp_ns;
    uint32_t canvas_width;
    uint32_t canvas_height;
    uint64_t native_base_sequence;
    uint64_t native_result_sequence;
    uint64_t native_result_checksum;
    uint16_t native_run_count;
    uint16_t patch_count;
    uint16_t atlas_width;
    uint16_t atlas_height;
    uint32_t atlas_bytes_per_row;
    uint32_t atlas_data_length;
    uint64_t atlas_checksum;
    struct tb_bc7_delta_run native_runs[TB_BC7_DELTA_MAX_RUNS];
    struct tb_bc7_adaptive_patch patches[TB_BC7_ADAPTIVE_MAX_PATCHES];
    const uint8_t *atlas_data;
};

struct tb_bc7_adaptive_state {
    uint32_t generation;
    uint64_t frame_id;
    uint64_t native_sequence;
    uint64_t native_checksum;
};

enum tb_bc7_adaptive_validation {
    TB_BC7_ADAPTIVE_VALID = 0,
    TB_BC7_ADAPTIVE_STALE = 1,
    TB_BC7_ADAPTIVE_INVALID = -1
};

uint64_t tb_bc7_adaptive_checksum(const uint8_t *data, size_t length);
int tb_bc7_adaptive_parse(const uint8_t *payload,
                          size_t payload_len,
                          struct tb_bc7_adaptive_frame *frame);
int tb_bc7_adaptive_validate_state(
    const struct tb_bc7_adaptive_frame *frame,
    const struct tb_bc7_adaptive_state *state,
    const uint64_t *tile_checksums,
    size_t tile_count,
    uint64_t *candidate_tile_checksums,
    uint64_t *native_result_checksum);

#endif
