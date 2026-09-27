#include "bc7_adaptive.h"

#include <string.h>

#define TB_BC7_ADAPTIVE_HEADER_SIZE 77u
#define TB_BC7_ADAPTIVE_PATCH_SIZE 16u

static uint16_t read_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)read_be32(p) << 32) | read_be32(p + 4);
}

uint64_t tb_bc7_adaptive_checksum(const uint8_t *data, size_t length) {
    if (!data && length != 0) return 0;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t index = 0; index < length; index++) {
        hash ^= data[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

int tb_bc7_adaptive_parse(const uint8_t *payload,
                          size_t payload_len,
                          struct tb_bc7_adaptive_frame *frame) {
    if (!payload || !frame || payload_len < TB_BC7_ADAPTIVE_HEADER_SIZE ||
        payload_len > TB_BC7_ADAPTIVE_MAX_PACKET_BYTES ||
        payload[0] != TB_BC7_ADAPTIVE_FORMAT_VERSION) {
        return -1;
    }

    memset(frame, 0, sizeof(*frame));
    frame->generation = read_be32(payload + 1);
    frame->frame_id = read_be64(payload + 5);
    frame->capture_timestamp_ns = read_be64(payload + 13);
    frame->canvas_width = read_be32(payload + 21);
    frame->canvas_height = read_be32(payload + 25);
    frame->native_base_sequence = read_be64(payload + 29);
    frame->native_result_sequence = read_be64(payload + 37);
    frame->native_result_checksum = read_be64(payload + 45);
    frame->native_run_count = read_be16(payload + 53);
    frame->patch_count = read_be16(payload + 55);
    frame->atlas_width = read_be16(payload + 57);
    frame->atlas_height = read_be16(payload + 59);
    frame->atlas_bytes_per_row = read_be32(payload + 61);
    frame->atlas_data_length = read_be32(payload + 65);
    frame->atlas_checksum = read_be64(payload + 69);

    if (frame->generation == 0 || frame->frame_id == 0 ||
        frame->canvas_width != TB_BC7_ADAPTIVE_CANVAS_WIDTH ||
        frame->canvas_height != TB_BC7_ADAPTIVE_CANVAS_HEIGHT ||
        frame->native_run_count > TB_BC7_DELTA_MAX_RUNS ||
        frame->patch_count > TB_BC7_ADAPTIVE_MAX_PATCHES ||
        frame->atlas_width == 0 || frame->atlas_height == 0 ||
        frame->atlas_width > TB_BC7_ADAPTIVE_MAX_ATLAS_WIDTH ||
        frame->atlas_height > TB_BC7_ADAPTIVE_MAX_ATLAS_HEIGHT ||
        (frame->atlas_width & 3u) || (frame->atlas_height & 3u)) {
        return -1;
    }

    const uint32_t expected_atlas_row_bytes =
        ((uint32_t)frame->atlas_width / 4u) * 16u;
    const size_t expected_atlas_length =
        (size_t)expected_atlas_row_bytes * ((uint32_t)frame->atlas_height / 4u);
    if (frame->atlas_bytes_per_row != expected_atlas_row_bytes ||
        frame->atlas_data_length != expected_atlas_length ||
        frame->atlas_data_length > TB_BC7_ADAPTIVE_MAX_ATLAS_BYTES) {
        return -1;
    }

    const uint32_t tiles_wide =
        frame->canvas_width / TB_BC7_DELTA_TILE_SIZE;
    const uint32_t tiles_high =
        frame->canvas_height / TB_BC7_DELTA_TILE_SIZE;
    uint8_t occupied[(TB_BC7_ADAPTIVE_CANVAS_WIDTH / TB_BC7_DELTA_TILE_SIZE) *
                     (TB_BC7_ADAPTIVE_CANVAS_HEIGHT / TB_BC7_DELTA_TILE_SIZE)] = {0};
    size_t offset = TB_BC7_ADAPTIVE_HEADER_SIZE;

    for (uint16_t index = 0; index < frame->native_run_count; index++) {
        if (offset > payload_len || payload_len - offset < 12u) return -1;
        struct tb_bc7_delta_run *run = &frame->native_runs[index];
        run->tile_x = read_be16(payload + offset);
        run->tile_y = read_be16(payload + offset + 2);
        run->tile_count_x = read_be16(payload + offset + 4);
        run->pixel_height = read_be16(payload + offset + 6);
        run->data_length = read_be32(payload + offset + 8);
        offset += 12u;

        if (run->tile_count_x == 0 || run->tile_y >= tiles_high ||
            (uint32_t)run->tile_x + run->tile_count_x > tiles_wide) {
            return -1;
        }
        const uint32_t expected_height =
            frame->canvas_height - (uint32_t)run->tile_y * TB_BC7_DELTA_TILE_SIZE <
                    TB_BC7_DELTA_TILE_SIZE
                ? frame->canvas_height -
                    (uint32_t)run->tile_y * TB_BC7_DELTA_TILE_SIZE
                : TB_BC7_DELTA_TILE_SIZE;
        const uint32_t run_row_bytes =
            (uint32_t)run->tile_count_x *
            (TB_BC7_DELTA_TILE_SIZE / 4u) * 16u;
        const size_t expected_length =
            (size_t)run_row_bytes * (expected_height / 4u);
        if (run->pixel_height != expected_height ||
            (run->pixel_height & 3u) ||
            run->data_length != expected_length ||
            offset > payload_len || run->data_length > payload_len - offset) {
            return -1;
        }
        for (uint16_t x = 0; x < run->tile_count_x; x++) {
            const size_t tile_index =
                (size_t)run->tile_y * tiles_wide + run->tile_x + x;
            if (occupied[tile_index]) return -1;
            occupied[tile_index] = 1;
        }
        run->data = payload + offset;
        offset += run->data_length;
    }

    const size_t descriptor_bytes =
        (size_t)frame->patch_count * TB_BC7_ADAPTIVE_PATCH_SIZE;
    if (offset > payload_len || descriptor_bytes > payload_len - offset) return -1;
    for (uint16_t index = 0; index < frame->patch_count; index++) {
        const uint8_t *descriptor =
            payload + offset + (size_t)index * TB_BC7_ADAPTIVE_PATCH_SIZE;
        struct tb_bc7_adaptive_patch *patch = &frame->patches[index];
        patch->destination_x = read_be16(descriptor);
        patch->destination_y = read_be16(descriptor + 2);
        patch->destination_width = read_be16(descriptor + 4);
        patch->destination_height = read_be16(descriptor + 6);
        patch->atlas_source_x = read_be16(descriptor + 8);
        patch->atlas_source_y = read_be16(descriptor + 10);
        patch->atlas_source_width = read_be16(descriptor + 12);
        patch->atlas_source_height = read_be16(descriptor + 14);

        if (patch->destination_width == 0 || patch->destination_height == 0 ||
            patch->atlas_source_width == 0 || patch->atlas_source_height == 0 ||
            (patch->atlas_source_x & 3u) || (patch->atlas_source_y & 3u) ||
            (patch->atlas_source_width & 3u) ||
            (patch->atlas_source_height & 3u) ||
            (uint32_t)patch->destination_x + patch->destination_width >
                frame->canvas_width ||
            (uint32_t)patch->destination_y + patch->destination_height >
                frame->canvas_height ||
            (uint32_t)patch->atlas_source_x + patch->atlas_source_width >
                frame->atlas_width ||
            (uint32_t)patch->atlas_source_y + patch->atlas_source_height >
                frame->atlas_height) {
            return -1;
        }
    }
    offset += descriptor_bytes;

    if (offset > payload_len ||
        frame->atlas_data_length != payload_len - offset) {
        return -1;
    }
    frame->atlas_data = payload + offset;
    return 0;
}

int tb_bc7_adaptive_validate_state(
    const struct tb_bc7_adaptive_frame *frame,
    const struct tb_bc7_adaptive_state *state,
    const uint64_t *tile_checksums,
    size_t tile_count,
    uint64_t *candidate_tile_checksums,
    uint64_t *native_result_checksum) {
    if (!frame || !state || !tile_checksums || !candidate_tile_checksums ||
        !native_result_checksum) {
        return TB_BC7_ADAPTIVE_INVALID;
    }
    if (frame->generation < state->generation ||
        (frame->generation == state->generation &&
         frame->frame_id <= state->frame_id)) {
        return TB_BC7_ADAPTIVE_STALE;
    }
    if (frame->generation != state->generation) {
        return TB_BC7_ADAPTIVE_INVALID;
    }
    if (frame->native_base_sequence != state->native_sequence ||
        (frame->native_result_sequence != frame->native_base_sequence &&
         (frame->native_base_sequence == UINT64_MAX ||
          frame->native_result_sequence != frame->native_base_sequence + 1u)) ||
        (frame->native_result_sequence == frame->native_base_sequence &&
         frame->native_run_count != 0)) {
        return TB_BC7_ADAPTIVE_INVALID;
    }
    if (tb_bc7_adaptive_checksum(frame->atlas_data, frame->atlas_data_length) !=
        frame->atlas_checksum) {
        return TB_BC7_ADAPTIVE_INVALID;
    }
    if (frame->native_run_count == 0) {
        if (frame->native_result_checksum != state->native_checksum) {
            return TB_BC7_ADAPTIVE_INVALID;
        }
        *native_result_checksum = state->native_checksum;
        return TB_BC7_ADAPTIVE_VALID;
    }

    struct tb_bc7_delta_frame native_delta = {
        .sequence = frame->native_result_sequence,
        .base_sequence = frame->native_base_sequence,
        .checksum = frame->native_result_checksum,
        .width = frame->canvas_width,
        .height = frame->canvas_height,
        .tile_size = TB_BC7_DELTA_TILE_SIZE,
        .run_count = frame->native_run_count
    };
    memcpy(native_delta.runs,
           frame->native_runs,
           (size_t)frame->native_run_count * sizeof(frame->native_runs[0]));
    return tb_bc7_delta_validate_candidate(
               &native_delta,
               tile_checksums,
               tile_count,
               state->native_checksum,
               candidate_tile_checksums,
               native_result_checksum) == 0
        ? TB_BC7_ADAPTIVE_VALID
        : TB_BC7_ADAPTIVE_INVALID;
}
