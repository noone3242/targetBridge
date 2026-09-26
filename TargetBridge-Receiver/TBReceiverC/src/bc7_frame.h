#ifndef TB_BC7_FRAME_H
#define TB_BC7_FRAME_H

#include <stddef.h>
#include <stdint.h>

struct tb_bc7_frame {
    const uint8_t *blocks;
    size_t blocks_len;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
};

int tb_bc7_frame_parse(const uint8_t *payload,
                       size_t payload_len,
                       struct tb_bc7_frame *frame);

#endif
