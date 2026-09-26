#include "bc7_frame.h"

#include <stdint.h>

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

int tb_bc7_frame_parse(const uint8_t *payload,
                       size_t payload_len,
                       struct tb_bc7_frame *frame) {
    if (!payload || !frame || payload_len < 13 || payload[0] != 1) return -1;

    uint32_t width = read_be32(payload + 1);
    uint32_t height = read_be32(payload + 5);
    uint32_t bytes_per_row = read_be32(payload + 9);
    if (width == 0 || height == 0 || (width & 3u) || (height & 3u) ||
        width > 8192 || height > 8192) {
        return -1;
    }

    uint32_t expected_bytes_per_row = (width / 4u) * 16u;
    if (bytes_per_row != expected_bytes_per_row) return -1;

    size_t block_rows = height / 4u;
    if ((size_t)bytes_per_row > SIZE_MAX / block_rows) return -1;
    size_t blocks_len = (size_t)bytes_per_row * block_rows;
    if (payload_len - 13 != blocks_len) return -1;

    frame->blocks = payload + 13;
    frame->blocks_len = blocks_len;
    frame->width = width;
    frame->height = height;
    frame->bytes_per_row = bytes_per_row;
    return 0;
}
