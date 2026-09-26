#include "bc7_frame.h"

#include <stdint.h>

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)read_be32(p) << 32) | read_be32(p + 4);
}

int tb_bc7_frame_parse(const uint8_t *payload,
                       size_t payload_len,
                       struct tb_bc7_frame *frame) {
    if (!payload || !frame || payload_len < 13) return -1;

    size_t header_size;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    frame->format = payload[0];
    frame->sequence = 0;
    frame->checksum = 0;
    if (payload[0] == 1) {
        header_size = 13;
        width = read_be32(payload + 1);
        height = read_be32(payload + 5);
        bytes_per_row = read_be32(payload + 9);
    } else if (payload[0] == 2 && payload_len >= 29) {
        header_size = 29;
        frame->sequence = read_be64(payload + 1);
        frame->checksum = read_be64(payload + 9);
        if (frame->sequence == 0) return -1;
        width = read_be32(payload + 17);
        height = read_be32(payload + 21);
        bytes_per_row = read_be32(payload + 25);
    } else {
        return -1;
    }
    if (width == 0 || height == 0 || (width & 3u) || (height & 3u) ||
        width > 8192 || height > 8192) {
        return -1;
    }

    uint32_t expected_bytes_per_row = (width / 4u) * 16u;
    if (bytes_per_row != expected_bytes_per_row) return -1;

    size_t block_rows = height / 4u;
    if ((size_t)bytes_per_row > SIZE_MAX / block_rows) return -1;
    size_t blocks_len = (size_t)bytes_per_row * block_rows;
    if (payload_len - header_size != blocks_len) return -1;

    frame->blocks = payload + header_size;
    frame->blocks_len = blocks_len;
    frame->width = width;
    frame->height = height;
    frame->bytes_per_row = bytes_per_row;
    return 0;
}
