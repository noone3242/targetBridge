#include "nv12_tile_runs.h"

#include <limits.h>

#define TB_NV12_TILE_RUN_MAX_BYTES (64u * 1024u * 1024u)

static uint16_t read_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)read_be32(p) << 32) | read_be32(p + 4);
}

int tb_nv12_tile_run_parse(
    const uint8_t *payload,
    size_t payload_length,
    struct tb_nv12_tile_run_frame *frame,
    struct tb_nv12_tile_run *runs,
    size_t run_capacity) {
    if (!payload || !frame || !runs ||
        payload_length < TB_NV12_TILE_RUN_HEADER_BYTES ||
        payload[0] != TB_NV12_TILE_RUN_FORMAT ||
        payload[1] != TB_NV12_TILE_RUN_COMPRESSION_LZ4 ||
        read_be16(payload + 2) != TB_NV12_TILE_RUN_SIZE) {
        return -1;
    }

    const uint32_t width = read_be32(payload + 4);
    const uint32_t height = read_be32(payload + 8);
    const uint32_t run_count = read_be32(payload + 12);
    const uint32_t raw_length = read_be32(payload + 16);
    const uint32_t compressed_length = read_be32(payload + 20);
    const uint64_t checksum = read_be64(payload + 24);
    if (width == 0 || height == 0 || width > 8192u || height > 8192u ||
        width % TB_NV12_TILE_RUN_SIZE != 0 ||
        height % TB_NV12_TILE_RUN_SIZE != 0 ||
        run_count == 0 || run_count > TB_NV12_TILE_RUN_MAX_RUNS ||
        run_count > run_capacity ||
        raw_length == 0 || raw_length > TB_NV12_TILE_RUN_MAX_BYTES ||
        compressed_length < 4u ||
        compressed_length > TB_NV12_TILE_RUN_MAX_BYTES) {
        return -1;
    }

    const size_t descriptor_bytes =
        (size_t)run_count * TB_NV12_TILE_RUN_DESCRIPTOR_BYTES;
    if (descriptor_bytes >
            payload_length - TB_NV12_TILE_RUN_HEADER_BYTES ||
        compressed_length !=
            payload_length - TB_NV12_TILE_RUN_HEADER_BYTES -
                descriptor_bytes) {
        return -1;
    }
    const uint8_t *compressed =
        payload + TB_NV12_TILE_RUN_HEADER_BYTES + descriptor_bytes;
    if (compressed[compressed_length - 4u] != 0x62u ||
        compressed[compressed_length - 3u] != 0x76u ||
        compressed[compressed_length - 2u] != 0x34u ||
        compressed[compressed_length - 1u] != 0x24u) {
        return -1;
    }

    const uint32_t tiles_wide = width / TB_NV12_TILE_RUN_SIZE;
    const uint32_t tiles_high = height / TB_NV12_TILE_RUN_SIZE;
    uint32_t expected_offset = 0;
    uint32_t previous_tile_y = UINT32_MAX;
    uint32_t previous_tile_end_x = 0;
    for (uint32_t index = 0; index < run_count; index++) {
        const uint8_t *descriptor =
            payload + TB_NV12_TILE_RUN_HEADER_BYTES +
            (size_t)index * TB_NV12_TILE_RUN_DESCRIPTOR_BYTES;
        struct tb_nv12_tile_run run = {
            .tile_x = read_be16(descriptor),
            .tile_y = read_be16(descriptor + 2),
            .tile_count_x = read_be16(descriptor + 4),
            .pixel_height = read_be16(descriptor + 6),
            .data_offset = read_be32(descriptor + 8),
            .data_length = read_be32(descriptor + 12)
        };
        const uint64_t pixel_width =
            (uint64_t)run.tile_count_x * TB_NV12_TILE_RUN_SIZE;
        const uint64_t expected_length =
            pixel_width * run.pixel_height * 3u / 2u;
        if (run.tile_count_x == 0 ||
            run.tile_y >= tiles_high ||
            (uint32_t)run.tile_x + run.tile_count_x > tiles_wide ||
            run.pixel_height != TB_NV12_TILE_RUN_SIZE ||
            run.data_offset != expected_offset ||
            expected_length > UINT32_MAX ||
            run.data_length != (uint32_t)expected_length ||
            run.data_offset > raw_length ||
            run.data_length > raw_length - run.data_offset ||
            (previous_tile_y != UINT32_MAX &&
             (run.tile_y < previous_tile_y ||
              (run.tile_y == previous_tile_y &&
               run.tile_x < previous_tile_end_x)))) {
            return -1;
        }
        runs[index] = run;
        expected_offset += run.data_length;
        previous_tile_y = run.tile_y;
        previous_tile_end_x = (uint32_t)run.tile_x + run.tile_count_x;
    }
    if (expected_offset != raw_length) return -1;

    frame->width = width;
    frame->height = height;
    frame->run_count = run_count;
    frame->raw_length = raw_length;
    frame->compressed_length = compressed_length;
    frame->checksum = checksum;
    frame->compressed = compressed;
    return 0;
}
