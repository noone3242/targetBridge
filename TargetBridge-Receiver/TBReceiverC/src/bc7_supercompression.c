#include "bc7_supercompression.h"
#include "bc7_delta.h"

#include <compression.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TB_BC7_SUPERCOMPRESSION_VERSION 1u
#define TB_BC7_SUPERCOMPRESSION_LZFSE 1u
#define TB_BC7_SUPERCOMPRESSION_BYTE_PLANES 1u
#define TB_BC7_SUPERCOMPRESSION_HEADER_BYTES 24u
#define TB_BC7_SUPERCOMPRESSION_MAX_BYTES (64u * 1024u * 1024u)

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

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

int tb_bc7_plane_split(
    const uint8_t *blocks,
    size_t blocks_len,
    uint8_t *planes) {
    if (!blocks || !planes || blocks_len == 0 || blocks_len % 16u != 0) {
        return -1;
    }
    const size_t block_count = blocks_len / 16u;
    for (size_t byte_index = 0; byte_index < 16u; byte_index++) {
        const size_t plane_offset = byte_index * block_count;
        for (size_t block_index = 0; block_index < block_count; block_index++) {
            planes[plane_offset + block_index] =
                blocks[block_index * 16u + byte_index];
        }
    }
    return 0;
}

int tb_bc7_plane_unsplit(
    const uint8_t *planes,
    size_t planes_len,
    uint8_t *blocks) {
    if (!planes || !blocks || planes_len == 0 || planes_len % 16u != 0) {
        return -1;
    }
    const size_t block_count = planes_len / 16u;
    for (size_t byte_index = 0; byte_index < 16u; byte_index++) {
        const size_t plane_offset = byte_index * block_count;
        for (size_t block_index = 0; block_index < block_count; block_index++) {
            blocks[block_index * 16u + byte_index] =
                planes[plane_offset + block_index];
        }
    }
    return 0;
}

uint64_t tb_bc7_supercompression_checksum(
    const uint8_t *data,
    size_t length) {
    if (!data && length != 0) return 0;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t index = 0; index < length; index++) {
        hash ^= data[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

struct tb_bc7_compressed_wrapper {
    const uint8_t *metadata;
    const uint8_t *compressed;
    size_t metadata_len;
    size_t blocks_len;
    size_t compressed_len;
};

static int parse_wrapper(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_compressed_wrapper *wrapper) {
    if (!payload || !wrapper ||
        payload_len < TB_BC7_SUPERCOMPRESSION_HEADER_BYTES ||
        payload[0] != TB_BC7_SUPERCOMPRESSION_VERSION ||
        payload[1] != TB_BC7_SUPERCOMPRESSION_LZFSE ||
        payload[2] != TB_BC7_SUPERCOMPRESSION_BYTE_PLANES ||
        payload[3] != 0) {
        return -1;
    }

    wrapper->metadata_len = read_be32(payload + 4);
    wrapper->blocks_len = read_be32(payload + 8);
    wrapper->compressed_len = read_be32(payload + 12);
    const uint64_t compressed_checksum = read_be64(payload + 16);
    if (wrapper->metadata_len == 0 ||
        wrapper->blocks_len == 0 ||
        wrapper->blocks_len % 16u != 0 ||
        wrapper->blocks_len > TB_BC7_SUPERCOMPRESSION_MAX_BYTES ||
        wrapper->compressed_len == 0 ||
        wrapper->compressed_len > TB_BC7_SUPERCOMPRESSION_MAX_BYTES ||
        wrapper->metadata_len >
            payload_len - TB_BC7_SUPERCOMPRESSION_HEADER_BYTES ||
        wrapper->compressed_len !=
            payload_len - TB_BC7_SUPERCOMPRESSION_HEADER_BYTES -
                wrapper->metadata_len) {
        return -1;
    }
    wrapper->metadata = payload + TB_BC7_SUPERCOMPRESSION_HEADER_BYTES;
    wrapper->compressed = wrapper->metadata + wrapper->metadata_len;
    if (wrapper->compressed_len < 4u ||
        wrapper->compressed[wrapper->compressed_len - 4u] != 0x62u ||
        wrapper->compressed[wrapper->compressed_len - 3u] != 0x76u ||
        wrapper->compressed[wrapper->compressed_len - 2u] != 0x78u ||
        wrapper->compressed[wrapper->compressed_len - 1u] != 0x24u) {
        return -1;
    }
    if (tb_bc7_supercompression_checksum(
            wrapper->compressed, wrapper->compressed_len) !=
        compressed_checksum) {
        return -1;
    }
    return 0;
}

static int validate_frame_wrapper(
    const struct tb_bc7_compressed_wrapper *wrapper) {
    if (!wrapper || !wrapper->metadata) return -1;
    const uint8_t format = wrapper->metadata[0];
    const size_t expected_metadata_len =
        format == 1u ? 13u : (format == 2u ? 29u : 0u);
    if (wrapper->metadata_len != expected_metadata_len) return -1;
    const size_t dimension_offset = format == 1u ? 1u : 17u;
    const uint32_t width = read_be32(wrapper->metadata + dimension_offset);
    const uint32_t height = read_be32(wrapper->metadata + dimension_offset + 4u);
    const uint32_t bytes_per_row =
        read_be32(wrapper->metadata + dimension_offset + 8u);
    if (width == 0 || height == 0 || width > 8192u || height > 8192u ||
        (width & 3u) || (height & 3u) ||
        bytes_per_row != (width / 4u) * 16u ||
        wrapper->blocks_len != (size_t)bytes_per_row * (height / 4u) ||
        wrapper->metadata_len + wrapper->blocks_len >
            TB_BC7_SUPERCOMPRESSION_MAX_BYTES - 1u) {
        return -1;
    }
    return 0;
}

static int validate_delta_wrapper(
    const struct tb_bc7_compressed_wrapper *wrapper) {
    if (!wrapper || !wrapper->metadata ||
        wrapper->metadata_len < 37u || wrapper->metadata[0] != 1u) {
        return -1;
    }
    const uint32_t width = read_be32(wrapper->metadata + 25u);
    const uint32_t height = read_be32(wrapper->metadata + 29u);
    const uint16_t tile_size = read_be16(wrapper->metadata + 33u);
    const uint16_t run_count = read_be16(wrapper->metadata + 35u);
    if (width == 0 || height == 0 || width > 8192u || height > 8192u ||
        (width & 3u) || (height & 3u) ||
        tile_size != TB_BC7_DELTA_TILE_SIZE ||
        width % tile_size != 0 ||
        run_count > TB_BC7_DELTA_MAX_RUNS ||
        wrapper->metadata_len != 37u + (size_t)run_count * 12u ||
        wrapper->metadata_len + wrapper->blocks_len >
            TB_BC7_SUPERCOMPRESSION_MAX_BYTES - 1u) {
        return -1;
    }

    const uint32_t tiles_wide = width / tile_size;
    const uint32_t tiles_high =
        (height + tile_size - 1u) / tile_size;
    size_t expected_blocks_len = 0;
    for (uint16_t index = 0; index < run_count; index++) {
        const size_t offset = 37u + (size_t)index * 12u;
        const uint16_t tile_x = read_be16(wrapper->metadata + offset);
        const uint16_t tile_y = read_be16(wrapper->metadata + offset + 2u);
        const uint16_t tile_count_x =
            read_be16(wrapper->metadata + offset + 4u);
        const uint16_t pixel_height =
            read_be16(wrapper->metadata + offset + 6u);
        const size_t data_len = read_be32(wrapper->metadata + offset + 8u);
        if (tile_count_x == 0 || tile_y >= tiles_high ||
            (uint32_t)tile_x + tile_count_x > tiles_wide) {
            return -1;
        }
        const uint32_t expected_height =
            height - (uint32_t)tile_y * tile_size < tile_size
                ? height - (uint32_t)tile_y * tile_size
                : tile_size;
        const size_t expected_data_len =
            (size_t)tile_count_x * (tile_size / 4u) * 16u *
            (expected_height / 4u);
        if (pixel_height != expected_height ||
            data_len != expected_data_len ||
            SIZE_MAX - expected_blocks_len < data_len) {
            return -1;
        }
        expected_blocks_len += data_len;
    }
    return expected_blocks_len == wrapper->blocks_len ? 0 : -1;
}

static int decode_exact(
    const struct tb_bc7_compressed_wrapper *wrapper,
    uint8_t **blocks,
    uint64_t *decompression_ns,
    uint64_t *inverse_ns) {
    if (!wrapper || !blocks || !decompression_ns || !inverse_ns ||
        wrapper->blocks_len == SIZE_MAX) {
        return -1;
    }
    uint8_t *planes = malloc(wrapper->blocks_len + 1u);
    uint8_t *blocks_copy = malloc(wrapper->blocks_len);
    if (!planes || !blocks_copy) {
        free(planes);
        free(blocks_copy);
        return -1;
    }

    compression_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_LZFSE) != COMPRESSION_STATUS_OK) {
        free(planes);
        free(blocks_copy);
        return -1;
    }
    stream.src_ptr = wrapper->compressed;
    stream.src_size = wrapper->compressed_len;
    stream.dst_ptr = planes;
    stream.dst_size = wrapper->blocks_len + 1u;

    const uint64_t decode_started = now_ns();
    compression_status status;
    do {
        const size_t previous_src_size = stream.src_size;
        const size_t previous_dst_size = stream.dst_size;
        status = compression_stream_process(
            &stream,
            COMPRESSION_STREAM_FINALIZE
        );
        if (status == COMPRESSION_STATUS_OK &&
            stream.src_size == previous_src_size &&
            stream.dst_size == previous_dst_size) {
            status = COMPRESSION_STATUS_ERROR;
        }
    } while (status == COMPRESSION_STATUS_OK && stream.dst_size > 0);
    const uint64_t decode_finished = now_ns();
    const size_t decoded = wrapper->blocks_len + 1u - stream.dst_size;
    const size_t remaining_input = stream.src_size;
    compression_stream_destroy(&stream);
    if (status != COMPRESSION_STATUS_END ||
        remaining_input != 0 ||
        decoded != wrapper->blocks_len) {
        free(planes);
        free(blocks_copy);
        return -1;
    }

    const uint64_t inverse_started = decode_finished;
    if (tb_bc7_plane_unsplit(
            planes, wrapper->blocks_len, blocks_copy) != 0) {
        free(planes);
        free(blocks_copy);
        return -1;
    }
    const uint64_t inverse_finished = now_ns();
    free(planes);

    *blocks = blocks_copy;
    *decompression_ns = decode_finished - decode_started;
    *inverse_ns = inverse_finished - inverse_started;
    return 0;
}

int tb_bc7_supercompression_decode_frame(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_supercompression_result *result) {
    if (!result) return -1;
    memset(result, 0, sizeof(*result));

    struct tb_bc7_compressed_wrapper wrapper;
    if (parse_wrapper(payload, payload_len, &wrapper) != 0 ||
        validate_frame_wrapper(&wrapper) != 0) {
        return -1;
    }
    uint8_t *blocks = NULL;
    uint64_t decompression_ns = 0;
    uint64_t inverse_ns = 0;
    if (decode_exact(
            &wrapper, &blocks, &decompression_ns, &inverse_ns) != 0) {
        return -1;
    }

    const size_t legacy_len = wrapper.metadata_len + wrapper.blocks_len;
    uint8_t *legacy = malloc(legacy_len);
    if (!legacy) {
        free(blocks);
        return -1;
    }
    memcpy(legacy, wrapper.metadata, wrapper.metadata_len);
    memcpy(legacy + wrapper.metadata_len, blocks, wrapper.blocks_len);
    free(blocks);

    result->payload = legacy;
    result->payload_len = legacy_len;
    result->raw_block_bytes = wrapper.blocks_len;
    result->compressed_block_bytes = wrapper.compressed_len;
    result->decompression_ns = decompression_ns;
    result->inverse_transform_ns = inverse_ns;
    return 0;
}

int tb_bc7_supercompression_decode_delta(
    const uint8_t *payload,
    size_t payload_len,
    struct tb_bc7_supercompression_result *result) {
    if (!result) return -1;
    memset(result, 0, sizeof(*result));

    struct tb_bc7_compressed_wrapper wrapper;
    if (parse_wrapper(payload, payload_len, &wrapper) != 0 ||
        validate_delta_wrapper(&wrapper) != 0) {
        return -1;
    }
    uint8_t *blocks = NULL;
    uint64_t decompression_ns = 0;
    uint64_t inverse_ns = 0;
    if (decode_exact(
            &wrapper, &blocks, &decompression_ns, &inverse_ns) != 0) {
        return -1;
    }

    const uint16_t run_count = read_be16(wrapper.metadata + 35u);
    const size_t legacy_len =
        37u + (size_t)run_count * 12u + wrapper.blocks_len;
    uint8_t *legacy = malloc(legacy_len);
    if (!legacy) {
        free(blocks);
        return -1;
    }
    memcpy(legacy, wrapper.metadata, 37u);
    size_t legacy_offset = 37u;
    size_t block_offset = 0;
    for (uint16_t index = 0; index < run_count; index++) {
        const size_t descriptor_offset = 37u + (size_t)index * 12u;
        const size_t run_len =
            read_be32(wrapper.metadata + descriptor_offset + 8u);
        memcpy(
            legacy + legacy_offset,
            wrapper.metadata + descriptor_offset,
            12u
        );
        legacy_offset += 12u;
        memcpy(legacy + legacy_offset, blocks + block_offset, run_len);
        legacy_offset += run_len;
        block_offset += run_len;
    }
    free(blocks);
    if (legacy_offset != legacy_len ||
        block_offset != wrapper.blocks_len) {
        free(legacy);
        return -1;
    }

    result->payload = legacy;
    result->payload_len = legacy_len;
    result->raw_block_bytes = wrapper.blocks_len;
    result->compressed_block_bytes = wrapper.compressed_len;
    result->decompression_ns = decompression_ns;
    result->inverse_transform_ns = inverse_ns;
    return 0;
}

void tb_bc7_supercompression_result_free(
    struct tb_bc7_supercompression_result *result) {
    if (!result) return;
    free(result->payload);
    memset(result, 0, sizeof(*result));
}
