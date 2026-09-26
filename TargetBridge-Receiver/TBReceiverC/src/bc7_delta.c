#include "bc7_delta.h"

#include <string.h>

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

int tb_bc7_delta_parse(const uint8_t *payload,
                       size_t payload_len,
                       struct tb_bc7_delta_frame *frame) {
    if (!payload || !frame || payload_len < 37 || payload[0] != 1) return -1;

    memset(frame, 0, sizeof(*frame));
    frame->sequence = read_be64(payload + 1);
    frame->base_sequence = read_be64(payload + 9);
    frame->checksum = read_be64(payload + 17);
    frame->width = read_be32(payload + 25);
    frame->height = read_be32(payload + 29);
    frame->tile_size = read_be16(payload + 33);
    frame->run_count = read_be16(payload + 35);

    if (frame->sequence == 0 || frame->width == 0 || frame->height == 0 ||
        frame->width > 8192 || frame->height > 8192 ||
        (frame->width & 3u) || (frame->height & 3u) ||
        frame->tile_size != TB_BC7_DELTA_TILE_SIZE ||
        frame->width % frame->tile_size != 0 ||
        frame->run_count > TB_BC7_DELTA_MAX_RUNS) {
        return -1;
    }

    const uint32_t tiles_wide = frame->width / frame->tile_size;
    const uint32_t tiles_high =
        (frame->height + frame->tile_size - 1u) / frame->tile_size;
    uint8_t occupied[(8192u / TB_BC7_DELTA_TILE_SIZE) *
                     (8192u / TB_BC7_DELTA_TILE_SIZE)] = {0};
    size_t offset = 37;

    for (uint16_t index = 0; index < frame->run_count; index++) {
        if (payload_len - offset < 12) return -1;
        struct tb_bc7_delta_run *run = &frame->runs[index];
        run->tile_x = read_be16(payload + offset);
        run->tile_y = read_be16(payload + offset + 2);
        run->tile_count_x = read_be16(payload + offset + 4);
        run->pixel_height = read_be16(payload + offset + 6);
        run->data_length = read_be32(payload + offset + 8);
        offset += 12;

        if (run->tile_count_x == 0 ||
            run->tile_y >= tiles_high ||
            (uint32_t)run->tile_x + run->tile_count_x > tiles_wide) {
            return -1;
        }
        const uint32_t expected_height =
            frame->height - (uint32_t)run->tile_y * frame->tile_size <
                    frame->tile_size
                ? frame->height - (uint32_t)run->tile_y * frame->tile_size
                : frame->tile_size;
        if (run->pixel_height != expected_height || (run->pixel_height & 3u)) {
            return -1;
        }
        const uint32_t run_row_bytes =
            (uint32_t)run->tile_count_x * (frame->tile_size / 4u) * 16u;
        const size_t expected_length =
            (size_t)run_row_bytes * (run->pixel_height / 4u);
        if (run->data_length != expected_length ||
            run->data_length > payload_len - offset) {
            return -1;
        }
        for (uint16_t x = 0; x < run->tile_count_x; x++) {
            size_t tile_index =
                (size_t)run->tile_y * tiles_wide + run->tile_x + x;
            if (occupied[tile_index]) return -1;
            occupied[tile_index] = 1;
        }
        run->data = payload + offset;
        offset += run->data_length;
    }

    return offset == payload_len ? 0 : -1;
}

int tb_bc7_delta_sequence_valid(uint64_t sequence,
                                uint64_t base_sequence,
                                uint64_t applied_sequence) {
    return base_sequence == applied_sequence &&
           base_sequence != UINT64_MAX &&
           sequence == base_sequence + 1u;
}

uint64_t tb_bc7_tile_checksum(const uint8_t *data,
                              uint32_t row_bytes,
                              uint32_t block_rows,
                              uint32_t tile_index) {
    if (!data || row_bytes == 0 || block_rows == 0) return 0;
    uint64_t hash = UINT64_C(14695981039346656037) ^ tile_index;
    for (uint32_t row = 0; row < block_rows; row++) {
        const uint8_t *row_data = data + (size_t)row * row_bytes;
        for (uint32_t index = 0;
             index < (TB_BC7_DELTA_TILE_SIZE / 4u) * 16u;
             index++) {
            hash ^= row_data[index];
            hash *= UINT64_C(1099511628211);
        }
    }
    return hash;
}

int tb_bc7_delta_apply_to_shadow(const struct tb_bc7_delta_frame *frame,
                                 uint8_t *shadow,
                                 size_t shadow_len,
                                 uint32_t bytes_per_row,
                                 uint64_t *tile_checksums,
                                 size_t tile_count,
                                 uint64_t *checksum) {
    if (!frame || !shadow || !tile_checksums || !checksum ||
        bytes_per_row != (frame->width / 4u) * 16u ||
        shadow_len != (size_t)bytes_per_row * (frame->height / 4u)) {
        return -1;
    }
    const uint32_t tiles_wide = frame->width / frame->tile_size;
    const uint32_t tiles_high =
        (frame->height + frame->tile_size - 1u) / frame->tile_size;
    if (tile_count != (size_t)tiles_wide * tiles_high) return -1;

    for (uint16_t index = 0; index < frame->run_count; index++) {
        const struct tb_bc7_delta_run *run = &frame->runs[index];
        const uint32_t run_row_bytes =
            (uint32_t)run->tile_count_x * (frame->tile_size / 4u) * 16u;
        const uint32_t block_rows = run->pixel_height / 4u;
        const size_t destination_x =
            (size_t)run->tile_x * (frame->tile_size / 4u) * 16u;
        const size_t destination_row =
            (size_t)run->tile_y * (frame->tile_size / 4u);
        for (uint32_t row = 0; row < block_rows; row++) {
            memcpy(shadow + (destination_row + row) * bytes_per_row + destination_x,
                   run->data + (size_t)row * run_row_bytes,
                   run_row_bytes);
        }
        for (uint16_t x = 0; x < run->tile_count_x; x++) {
            const uint32_t tile_x = run->tile_x + x;
            const size_t tile_index = (size_t)run->tile_y * tiles_wide + tile_x;
            const size_t tile_offset =
                destination_row * bytes_per_row +
                (size_t)tile_x * (frame->tile_size / 4u) * 16u;
            tile_checksums[tile_index] = tb_bc7_tile_checksum(
                shadow + tile_offset,
                bytes_per_row,
                block_rows,
                (uint32_t)tile_index
            );
        }
    }

    uint64_t calculated = 0;
    for (size_t index = 0; index < tile_count; index++) {
        calculated ^= tile_checksums[index];
    }
    if (calculated != frame->checksum) return -1;
    *checksum = calculated;
    return 0;
}
