#ifndef TB_BC7_SUPERCOMPRESSION_H
#define TB_BC7_SUPERCOMPRESSION_H

#include <stddef.h>
#include <stdint.h>

struct tb_bc7_supercompression_result {
    uint8_t *payload;
    size_t payload_len;
    size_t raw_block_bytes;
    size_t compressed_block_bytes;
    uint64_t decompression_ns;
    uint64_t inverse_transform_ns;
};

struct tb_bc7_supercompression_scratch {
    uint8_t *transformed;
    size_t transformed_capacity;
    uint8_t *blocks;
    size_t blocks_capacity;
    uint8_t *legacy;
    size_t legacy_capacity;
};

enum tb_bc7_compression_algorithm {
    TB_BC7_COMPRESSION_LZFSE = 1,
    TB_BC7_COMPRESSION_LZ4 = 2
};

enum tb_bc7_block_transform {
    TB_BC7_TRANSFORM_RAW = 0,
    TB_BC7_TRANSFORM_BYTE_PLANES = 1
};

int tb_bc7_supercompression_decode_frame(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_supercompression_result *result);
int tb_bc7_supercompression_decode_delta(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_supercompression_result *result);
int tb_bc7_supercompression_decode_frame_reuse(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_supercompression_scratch *scratch,
    struct tb_bc7_supercompression_result *result);
int tb_bc7_supercompression_decode_delta_reuse(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_supercompression_scratch *scratch,
    struct tb_bc7_supercompression_result *result);
void tb_bc7_supercompression_scratch_free(
    struct tb_bc7_supercompression_scratch *scratch);
void tb_bc7_supercompression_result_free(
    struct tb_bc7_supercompression_result *result);

int tb_bc7_plane_split(
    const uint8_t *blocks,
    size_t blocks_len,
    uint8_t *planes);
int tb_bc7_plane_unsplit(
    const uint8_t *planes,
    size_t planes_len,
    uint8_t *blocks);
uint64_t tb_bc7_supercompression_checksum(
    const uint8_t *data,
    size_t length);

#endif
