/* test_net_parser.c — hardware-free unit tests for the streaming packet
 * parser in net.c (the framing layer every receiver session depends on).
 *
 * Build & run:  make test
 *
 * Only needs net.c + POSIX — no ffmpeg, no SDL, no Thunderbolt. */

#include "../src/net.h"
#include "../src/proto.h"
#include "../src/bc7_frame.h"
#include "../src/bc7_delta.h"
#include "../src/bc7_supercompression.h"
#include "../src/bc7_cursor.h"

#include <compression.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

/* ---- callback capture ------------------------------------------------- */

#define MAX_CAPTURED 16

struct captured_packet {
    uint8_t type;
    size_t  len;
    uint8_t payload[1024];
    int     had_nul_sentinel;   /* payload[len] was '\0' during the callback */
};

static struct captured_packet g_captured[MAX_CAPTURED];
static int g_captured_count = 0;

static void capture_cb(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    (void)ud;
    if (g_captured_count >= MAX_CAPTURED) return;
    struct captured_packet *c = &g_captured[g_captured_count++];
    c->type = type;
    c->len = len;
    if (len <= sizeof(c->payload)) memcpy(c->payload, payload, len);
    /* net.c promises a NUL one byte past the payload so string functions in
     * the callback cannot run off the end. */
    c->had_nul_sentinel = (payload[len] == '\0');
}

static void reset_capture(void) {
    memset(g_captured, 0, sizeof(g_captured));
    g_captured_count = 0;
}

/* ---- helpers ----------------------------------------------------------- */

static void put_be32(uint8_t *dst, uint32_t v) {
    dst[0] = (uint8_t)(v >> 24);
    dst[1] = (uint8_t)(v >> 16);
    dst[2] = (uint8_t)(v >> 8);
    dst[3] = (uint8_t)v;
}

static void put_be16(uint8_t *dst, uint16_t v) {
    dst[0] = (uint8_t)(v >> 8);
    dst[1] = (uint8_t)v;
}

static void put_be64(uint8_t *dst, uint64_t v) {
    put_be32(dst, (uint32_t)(v >> 32));
    put_be32(dst + 4, (uint32_t)v);
}

/* Builds [4B BE len][1B type][payload] into buf; returns total size. */
static size_t build_packet(uint8_t *buf, uint8_t type, const void *payload, size_t plen) {
    put_be32(buf, (uint32_t)(1 + plen));
    buf[4] = type;
    if (plen) memcpy(buf + 5, payload, plen);
    return 5 + plen;
}

/* ---- tests ------------------------------------------------------------- */

static void test_single_packet_whole_feed(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t pkt[64];
    size_t n = build_packet(pkt, TB_PKT_HELLO_RECEIVER, "hi", 2);

    CHECK(tb_parser_feed(&p, pkt, n) == 0, "feed should succeed");
    CHECK(g_captured_count == 1, "exactly one packet");
    CHECK(g_captured[0].type == TB_PKT_HELLO_RECEIVER, "type preserved");
    CHECK(g_captured[0].len == 2, "payload length preserved");
    CHECK(memcmp(g_captured[0].payload, "hi", 2) == 0, "payload bytes preserved");
    CHECK(g_captured[0].had_nul_sentinel, "NUL sentinel past payload");

    tb_parser_free(&p);
}

static void test_byte_by_byte_feed(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t pkt[64];
    size_t n = build_packet(pkt, TB_PKT_HEARTBEAT, "\x01\x02\x03", 3);

    for (size_t i = 0; i < n; i++) {
        CHECK(tb_parser_feed(&p, pkt + i, 1) == 0, "fragmented feed should succeed");
        if (i < n - 1) {
            CHECK(g_captured_count == 0, "must not fire before final byte");
        }
    }
    CHECK(g_captured_count == 1, "fires exactly once at final byte");
    CHECK(g_captured[0].len == 3, "payload length preserved across fragments");

    tb_parser_free(&p);
}

static void test_two_contiguous_packets(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t buf[128];
    size_t n1 = build_packet(buf, TB_PKT_HELLO_RECEIVER, "first", 5);
    size_t n2 = build_packet(buf + n1, TB_PKT_HEARTBEAT, "second!", 7);

    CHECK(tb_parser_feed(&p, buf, n1 + n2) == 0, "feed should succeed");
    CHECK(g_captured_count == 2, "both packets fire");
    CHECK(g_captured[0].type == TB_PKT_HELLO_RECEIVER, "first type");
    CHECK(memcmp(g_captured[0].payload, "first", 5) == 0, "first payload");
    /* The NUL sentinel for packet 1 lands on packet 2's length byte; the
     * save/restore in net.c must leave packet 2 intact. */
    CHECK(g_captured[1].type == TB_PKT_HEARTBEAT, "second type intact after sentinel restore");
    CHECK(g_captured[1].len == 7, "second length intact");
    CHECK(memcmp(g_captured[1].payload, "second!", 7) == 0, "second payload intact");

    tb_parser_free(&p);
}

static void test_split_across_feeds_with_remainder(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t buf[128];
    size_t n1 = build_packet(buf, TB_PKT_PARAM_SETS, "abcd", 4);
    size_t n2 = build_packet(buf + n1, TB_PKT_FRAME, "efghij", 6);

    /* Feed 1.5 packets, then the rest. */
    size_t first_chunk = n1 + 3;
    CHECK(tb_parser_feed(&p, buf, first_chunk) == 0, "first chunk ok");
    CHECK(g_captured_count == 1, "only complete packet fires");
    CHECK(tb_parser_feed(&p, buf + first_chunk, n1 + n2 - first_chunk) == 0, "second chunk ok");
    CHECK(g_captured_count == 2, "remainder completes second packet");
    CHECK(g_captured[1].type == TB_PKT_FRAME, "second packet type");
    CHECK(memcmp(g_captured[1].payload, "efghij", 6) == 0, "second packet payload");

    tb_parser_free(&p);
}

static void test_zero_length_is_fatal(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t bad[5] = {0x00, 0x00, 0x00, 0x00, 0x30};
    CHECK(tb_parser_feed(&p, bad, sizeof(bad)) == -1, "pkt_len=0 must be rejected");
    CHECK(g_captured_count == 0, "no callback for corrupt framing");

    tb_parser_free(&p);
}

static void test_oversized_length_is_fatal(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t bad[5];
    put_be32(bad, 64u * 1024 * 1024 + 1);  /* one past the 64 MiB sanity cap */
    bad[4] = 0x21;
    CHECK(tb_parser_feed(&p, bad, sizeof(bad)) == -1, "oversized pkt_len must be rejected");

    uint8_t worst[5] = {0xFF, 0xFF, 0xFF, 0xFF, 0x21};
    struct tb_parser p2;
    tb_parser_init(&p2, capture_cb, NULL);
    CHECK(tb_parser_feed(&p2, worst, sizeof(worst)) == -1, "0xFFFFFFFF pkt_len must be rejected");

    tb_parser_free(&p);
    tb_parser_free(&p2);
}

static void test_large_payload_roundtrip(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    size_t plen = 1024 * 1024;  /* 1 MiB, exercises parser_reserve growth */
    uint8_t *pkt = malloc(5 + plen);
    CHECK(pkt != NULL, "alloc");
    if (!pkt) return;
    put_be32(pkt, (uint32_t)(1 + plen));
    pkt[4] = TB_PKT_FRAME;
    for (size_t i = 0; i < plen; i++) pkt[5 + i] = (uint8_t)(i * 31);

    /* Feed in 64 KiB slices like a real socket drain. */
    size_t off = 0, total = 5 + plen;
    while (off < total) {
        size_t chunk = total - off > 65536 ? 65536 : total - off;
        CHECK(tb_parser_feed(&p, pkt + off, chunk) == 0, "chunked feed ok");
        off += chunk;
    }
    CHECK(g_captured_count == 1, "large packet fires once");
    CHECK(g_captured[0].len == plen, "large payload length preserved");

    free(pkt);
    tb_parser_free(&p);
}

static void test_bc7_packet_type(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t payload[13] = {
        1,
        0, 0, 0, 4,
        0, 0, 0, 4,
        0, 0, 0, 16
    };
    uint8_t packet[4 + 1 + sizeof(payload)];
    size_t n = build_packet(packet, TB_PKT_BC7_FRAME, payload, sizeof(payload));

    CHECK(tb_parser_feed(&p, packet, n) == 0, "BC7 packet parses");
    CHECK(g_captured_count == 1, "BC7 packet callback count");
    CHECK(g_captured[0].type == TB_PKT_BC7_FRAME, "BC7 packet type preserved");
    CHECK(g_captured[0].len == sizeof(payload), "BC7 payload length preserved");

    tb_parser_free(&p);
}

static void make_bc7_payload(uint8_t *payload,
                             uint8_t format,
                             uint32_t width,
                             uint32_t height,
                             uint32_t bytes_per_row) {
    payload[0] = format;
    put_be32(payload + 1, width);
    put_be32(payload + 5, height);
    put_be32(payload + 9, bytes_per_row);
}

static void test_bc7_payload_validation(void) {
    uint8_t payload[29] = {0};
    struct tb_bc7_frame frame;
    make_bc7_payload(payload, 1, 4, 4, 16);

    CHECK(tb_bc7_frame_parse(payload, sizeof(payload), &frame) == 0,
          "valid 4x4 BC7 payload accepted");
    CHECK(frame.blocks == payload + 13, "BC7 block pointer skips header");
    CHECK(frame.blocks_len == 16, "BC7 block length parsed");
    CHECK(frame.width == 4 && frame.height == 4, "BC7 dimensions parsed");
    CHECK(frame.bytes_per_row == 16, "BC7 row bytes parsed");

    payload[0] = 3;
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload), &frame) == -1,
          "unknown BC7 format rejected");

    make_bc7_payload(payload, 1, 5, 4, 16);
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload), &frame) == -1,
          "non-block-aligned width rejected");

    make_bc7_payload(payload, 1, 4, 0, 16);
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload), &frame) == -1,
          "zero height rejected");

    make_bc7_payload(payload, 1, 8196, 4, 32784);
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload), &frame) == -1,
          "oversized dimensions rejected");

    make_bc7_payload(payload, 1, 4, 4, 32);
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload), &frame) == -1,
          "incorrect BC7 row bytes rejected");

    make_bc7_payload(payload, 1, 4, 4, 16);
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload) - 1, &frame) == -1,
          "truncated BC7 block payload rejected");
    CHECK(tb_bc7_frame_parse(payload, sizeof(payload) + 1, &frame) == -1,
          "trailing BC7 payload bytes rejected");
}

static void test_bc7_sequenced_keyframe_validation(void) {
    const size_t blocks_len = 4096;
    uint8_t *payload = calloc(1, 29 + blocks_len);
    struct tb_bc7_frame frame;
    CHECK(payload != NULL, "sequenced keyframe alloc");
    if (!payload) return;
    payload[0] = 2;
    put_be64(payload + 1, 9);
    put_be64(payload + 9, UINT64_C(0x0123456789abcdef));
    put_be32(payload + 17, 64);
    put_be32(payload + 21, 64);
    put_be32(payload + 25, 256);
    CHECK(tb_bc7_frame_parse(payload, 29 + blocks_len, &frame) == 0,
          "sequenced BC7 keyframe accepted");
    CHECK(frame.format == 2, "sequenced keyframe format parsed");
    CHECK(frame.sequence == 9, "sequenced keyframe sequence parsed");
    CHECK(frame.checksum == UINT64_C(0x0123456789abcdef),
          "sequenced keyframe checksum parsed");
    CHECK(frame.blocks == payload + 29, "sequenced keyframe header skipped");
    put_be64(payload + 1, 0);
    CHECK(tb_bc7_frame_parse(payload, 29 + blocks_len, &frame) == -1,
          "zero sequenced keyframe rejected");
    free(payload);
}

static void test_bc7_delta_validation(void) {
    const size_t run_len = 4096;
    uint8_t *payload = calloc(1, 37 + 12 + run_len);
    struct tb_bc7_delta_frame frame;
    CHECK(payload != NULL, "delta alloc");
    if (!payload) return;
    payload[0] = 1;
    put_be64(payload + 1, 2);
    put_be64(payload + 9, 1);
    put_be64(payload + 17, UINT64_C(0xfedcba9876543210));
    put_be32(payload + 25, 64);
    put_be32(payload + 29, 64);
    put_be16(payload + 33, 64);
    put_be16(payload + 35, 1);
    put_be16(payload + 37, 0);
    put_be16(payload + 39, 0);
    put_be16(payload + 41, 1);
    put_be16(payload + 43, 64);
    put_be32(payload + 45, (uint32_t)run_len);
    for (size_t i = 0; i < run_len; i++) payload[49 + i] = (uint8_t)(i * 17u);
    put_be64(payload + 17, tb_bc7_tile_checksum(payload + 49, 256, 16, 0));

    CHECK(tb_bc7_delta_parse(payload, 49 + run_len, &frame) == 0,
          "valid one-tile delta accepted");
    CHECK(frame.sequence == 2 && frame.base_sequence == 1,
          "delta sequence pair parsed");
    CHECK(frame.run_count == 1, "delta run count parsed");
    CHECK(frame.runs[0].data_length == run_len, "delta run length parsed");
    CHECK(frame.runs[0].data == payload + 49, "delta run data pointer parsed");
    uint8_t shadow[4096] = {0};
    uint64_t tile_checksums[1] = {0};
    uint64_t applied_checksum = 0;
    CHECK(tb_bc7_delta_apply_to_shadow(
              &frame, shadow, sizeof(shadow), 256,
              tile_checksums, 1, &applied_checksum) == 0,
          "validated delta applies to candidate shadow");
    CHECK(memcmp(shadow, payload + 49, sizeof(shadow)) == 0,
          "shadow contains the delta tile bytes");
    CHECK(applied_checksum == frame.checksum,
          "applied shadow checksum matches wire checksum");
    memset(shadow, 0, sizeof(shadow));
    tile_checksums[0] = 0;
    uint64_t candidate_checksums[1] = {0};
    CHECK(tb_bc7_delta_validate_candidate(
              &frame, tile_checksums, 1, 0,
              candidate_checksums, &applied_checksum) == 0,
          "candidate checksum validates before live-state mutation");
    CHECK(shadow[0] == 0 && tile_checksums[0] == 0,
          "validation leaves live shadow and checksums unchanged");
    CHECK(tb_bc7_delta_commit_to_shadow(
              &frame, shadow, sizeof(shadow), 256,
              tile_checksums, 1, candidate_checksums) == 0,
          "validated candidate commits in place");
    CHECK(memcmp(shadow, payload + 49, sizeof(shadow)) == 0,
          "in-place commit copies the validated tile");
    CHECK(!tb_bc7_delta_prefers_full_upload(&frame, 32768),
          "single small run keeps regional upload");
    frame.run_count = 9;
    for (uint16_t index = 1; index < frame.run_count; index++) {
        frame.runs[index].data_length = 1;
    }

    {
        const size_t blocks_len = 64u * 1024u;
        uint8_t *blocks = malloc(blocks_len);
        uint8_t *planes = malloc(blocks_len);
        uint8_t *compressed = malloc(blocks_len + 65536u);
        CHECK(blocks && planes && compressed, "supercompression buffers allocated");
        if (!blocks || !planes || !compressed) {
            free(blocks);
            free(planes);
            free(compressed);
            return;
        }
        memset(blocks, 0x5a, blocks_len);
        CHECK(tb_bc7_plane_split(blocks, blocks_len, planes) == 0,
              "BC7 byte planes split");
        uint8_t *roundtrip = malloc(blocks_len);
        CHECK(roundtrip != NULL, "plane roundtrip allocated");
        if (roundtrip) {
            CHECK(tb_bc7_plane_unsplit(planes, blocks_len, roundtrip) == 0,
                  "BC7 byte planes unsplit");
            CHECK(memcmp(roundtrip, blocks, blocks_len) == 0,
                  "BC7 byte planes round trip exactly");
        }
        free(roundtrip);

        size_t compressed_len = compression_encode_buffer(
            compressed,
            blocks_len + 65536u,
            planes,
            blocks_len,
            NULL,
            COMPRESSION_LZFSE
        );
        CHECK(compressed_len > 0 && compressed_len < blocks_len,
              "LZFSE compresses repetitive BC7 planes");
        if (compressed_len == 0) {
            free(blocks);
            free(planes);
            free(compressed);
            return;
        }

        uint8_t metadata[13] = {0};
        metadata[0] = 1;
        put_be32(metadata + 1, 256);
        put_be32(metadata + 5, 256);
        put_be32(metadata + 9, 1024);
        const size_t wrapper_len = 24u + sizeof(metadata) + compressed_len;
        uint8_t *wrapper = calloc(1, wrapper_len);
        CHECK(wrapper != NULL, "compressed frame wrapper allocated");
        if (!wrapper) {
            free(blocks);
            free(planes);
            free(compressed);
            return;
        }
        wrapper[0] = 1;
        wrapper[1] = TB_BC7_COMPRESSION_LZFSE;
        wrapper[2] = TB_BC7_TRANSFORM_BYTE_PLANES;
        put_be32(wrapper + 4, (uint32_t)sizeof(metadata));
        put_be32(wrapper + 8, (uint32_t)blocks_len);
        put_be32(wrapper + 12, (uint32_t)compressed_len);
        put_be64(
            wrapper + 16,
            tb_bc7_supercompression_checksum(compressed, compressed_len)
        );
        memcpy(wrapper + 24, metadata, sizeof(metadata));
        memcpy(wrapper + 24 + sizeof(metadata), compressed, compressed_len);

        struct tb_bc7_supercompression_result result;
        CHECK(tb_bc7_supercompression_decode_frame(
                  wrapper, wrapper_len, &result) == 0,
              "compressed BC7 frame decodes");
        CHECK(result.payload_len == sizeof(metadata) + blocks_len,
              "decoded frame has legacy payload length");
        CHECK(memcmp(result.payload, metadata, sizeof(metadata)) == 0,
              "decoded frame metadata preserved");
        CHECK(memcmp(result.payload + sizeof(metadata), blocks, blocks_len) == 0,
              "decoded frame BC7 blocks preserved");
        CHECK(result.compressed_block_bytes == compressed_len,
              "compressed byte count reported");
        tb_bc7_supercompression_result_free(&result);

        uint8_t *lz4_compressed = malloc(blocks_len + 65536u);
        CHECK(lz4_compressed != NULL, "LZ4 compressed buffer allocated");
        size_t lz4_compressed_len = lz4_compressed
            ? compression_encode_buffer(
            lz4_compressed,
            blocks_len + 65536u,
            blocks,
            blocks_len,
            NULL,
            COMPRESSION_LZ4
        ) : 0;
        CHECK(lz4_compressed_len > 0 && lz4_compressed_len < blocks_len,
              "LZ4 compresses repetitive raw BC7");
        if (lz4_compressed_len > 0) {
            const size_t lz4_wrapper_len =
                24u + sizeof(metadata) + lz4_compressed_len;
            uint8_t *lz4_wrapper = calloc(1, lz4_wrapper_len);
            CHECK(lz4_wrapper != NULL, "LZ4 frame wrapper allocated");
            if (lz4_wrapper) {
                lz4_wrapper[0] = 1;
                lz4_wrapper[1] = TB_BC7_COMPRESSION_LZ4;
                lz4_wrapper[2] = TB_BC7_TRANSFORM_RAW;
                put_be32(lz4_wrapper + 4, (uint32_t)sizeof(metadata));
                put_be32(lz4_wrapper + 8, (uint32_t)blocks_len);
                put_be32(lz4_wrapper + 12, (uint32_t)lz4_compressed_len);
                put_be64(
                    lz4_wrapper + 16,
                    tb_bc7_supercompression_checksum(
                        lz4_compressed,
                        lz4_compressed_len
                    )
                );
                memcpy(lz4_wrapper + 24, metadata, sizeof(metadata));
                memcpy(
                    lz4_wrapper + 24 + sizeof(metadata),
                    lz4_compressed,
                    lz4_compressed_len
                );
                CHECK(tb_bc7_supercompression_decode_frame(
                          lz4_wrapper, lz4_wrapper_len, &result) == 0,
                      "raw BC7 LZ4 frame decodes");
                CHECK(memcmp(
                          result.payload + sizeof(metadata),
                          blocks,
                          blocks_len) == 0,
                      "raw BC7 LZ4 blocks preserved");
                CHECK(result.inverse_transform_ns == 0,
                      "raw BC7 LZ4 skips inverse transform");
                tb_bc7_supercompression_result_free(&result);
                uint8_t *lz4_trailing = malloc(lz4_wrapper_len + 1u);
                CHECK(lz4_trailing != NULL, "LZ4 trailing fixture allocated");
                if (lz4_trailing) {
                    memcpy(lz4_trailing, lz4_wrapper, lz4_wrapper_len);
                    lz4_trailing[lz4_wrapper_len] = 0xa5;
                    put_be32(
                        lz4_trailing + 12,
                        (uint32_t)lz4_compressed_len + 1u
                    );
                    put_be64(
                        lz4_trailing + 16,
                        tb_bc7_supercompression_checksum(
                            lz4_trailing + 24 + sizeof(metadata),
                            lz4_compressed_len + 1u
                        )
                    );
                    CHECK(tb_bc7_supercompression_decode_frame(
                              lz4_trailing,
                              lz4_wrapper_len + 1u,
                              &result) == -1,
                          "LZ4 trailing compressed bytes rejected");
                    free(lz4_trailing);
                }
                lz4_wrapper[2] = TB_BC7_TRANSFORM_BYTE_PLANES;
                CHECK(tb_bc7_supercompression_decode_frame(
                          lz4_wrapper, lz4_wrapper_len, &result) == -1,
                      "unsupported LZ4 byte-plane pairing rejected");
                free(lz4_wrapper);
            }
        }
        free(lz4_compressed);

        uint8_t *trailing = malloc(wrapper_len + 1u);
        CHECK(trailing != NULL, "trailing-data fixture allocated");
        if (trailing) {
            memcpy(trailing, wrapper, wrapper_len);
            trailing[wrapper_len] = 0xa5;
            put_be32(trailing + 12, (uint32_t)compressed_len + 1u);
            CHECK(tb_bc7_supercompression_decode_frame(
                      trailing, wrapper_len + 1u, &result) == -1,
                  "trailing compressed bytes rejected by checksum");
            put_be64(
                trailing + 16,
                tb_bc7_supercompression_checksum(
                    trailing + 24 + sizeof(metadata),
                    compressed_len + 1u
                )
            );
            CHECK(tb_bc7_supercompression_decode_frame(
                      trailing, wrapper_len + 1u, &result) == -1,
                  "trailing compressed bytes rejected after checksum recompute");
            free(trailing);
        }
        uint8_t *bad_checksum = malloc(wrapper_len);
        CHECK(bad_checksum != NULL, "bad-checksum fixture allocated");
        if (bad_checksum) {
            memcpy(bad_checksum, wrapper, wrapper_len);
            bad_checksum[16] ^= 1u;
            CHECK(tb_bc7_supercompression_decode_frame(
                      bad_checksum, wrapper_len, &result) == -1,
                  "compressed checksum mismatch rejected");
            free(bad_checksum);
        }

        const size_t extra_planes_len = blocks_len + 16u;
        uint8_t *extra_planes = malloc(extra_planes_len);
        uint8_t *extra_compressed = malloc(extra_planes_len + 65536u);
        CHECK(extra_planes && extra_compressed, "overlong-output fixture allocated");
        if (extra_planes && extra_compressed) {
            memcpy(extra_planes, planes, blocks_len);
            memset(extra_planes + blocks_len, 0x7c, 16u);
            const size_t extra_compressed_len = compression_encode_buffer(
                extra_compressed,
                extra_planes_len + 65536u,
                extra_planes,
                extra_planes_len,
                NULL,
                COMPRESSION_LZFSE
            );
            CHECK(extra_compressed_len > 0, "overlong planes compressed");
            if (extra_compressed_len > 0) {
                const size_t extra_wrapper_len =
                    24u + sizeof(metadata) + extra_compressed_len;
                uint8_t *extra_wrapper = calloc(1, extra_wrapper_len);
                CHECK(extra_wrapper != NULL, "overlong-output wrapper allocated");
                if (extra_wrapper) {
                    extra_wrapper[0] = 1;
                    extra_wrapper[1] = TB_BC7_COMPRESSION_LZFSE;
                    extra_wrapper[2] = TB_BC7_TRANSFORM_BYTE_PLANES;
                    put_be32(extra_wrapper + 4, (uint32_t)sizeof(metadata));
                    put_be32(extra_wrapper + 8, (uint32_t)blocks_len);
                    put_be32(
                        extra_wrapper + 12,
                        (uint32_t)extra_compressed_len
                    );
                    put_be64(
                        extra_wrapper + 16,
                        tb_bc7_supercompression_checksum(
                            extra_compressed,
                            extra_compressed_len
                        )
                    );
                    memcpy(extra_wrapper + 24, metadata, sizeof(metadata));
                    memcpy(
                        extra_wrapper + 24 + sizeof(metadata),
                        extra_compressed,
                        extra_compressed_len
                    );
                    CHECK(tb_bc7_supercompression_decode_frame(
                              extra_wrapper, extra_wrapper_len, &result) == -1,
                          "decompressed output beyond declared length rejected");
                    free(extra_wrapper);
                }
            }
        }
        free(extra_planes);
        free(extra_compressed);
        uint8_t *invalid_metadata = calloc(1, wrapper_len + 1u);
        CHECK(invalid_metadata != NULL, "invalid-metadata fixture allocated");
        if (invalid_metadata) {
            invalid_metadata[0] = 1;
            invalid_metadata[1] = TB_BC7_COMPRESSION_LZFSE;
            invalid_metadata[2] = TB_BC7_TRANSFORM_BYTE_PLANES;
            put_be32(invalid_metadata + 4, (uint32_t)sizeof(metadata) + 1u);
            put_be32(invalid_metadata + 8, (uint32_t)blocks_len);
            put_be32(invalid_metadata + 12, (uint32_t)compressed_len);
            put_be64(
                invalid_metadata + 16,
                tb_bc7_supercompression_checksum(compressed, compressed_len)
            );
            memcpy(invalid_metadata + 24, metadata, sizeof(metadata));
            memcpy(
                invalid_metadata + 24 + sizeof(metadata) + 1u,
                compressed,
                compressed_len
            );
            CHECK(tb_bc7_supercompression_decode_frame(
                      invalid_metadata, wrapper_len + 1u, &result) == -1,
                  "invalid frame metadata rejected before decode");
            free(invalid_metadata);
        }

        wrapper[2] = 2;
        CHECK(tb_bc7_supercompression_decode_frame(
                  wrapper, wrapper_len, &result) == -1,
              "unknown plane transform rejected");
        wrapper[2] = TB_BC7_TRANSFORM_BYTE_PLANES;
        put_be32(wrapper + 8, (uint32_t)blocks_len - 1u);
        CHECK(tb_bc7_supercompression_decode_frame(
                  wrapper, wrapper_len, &result) == -1,
              "non-block-aligned decoded length rejected");
    put_be32(wrapper + 8, (uint32_t)blocks_len);

        uint8_t delta_metadata[49] = {0};
        delta_metadata[0] = 1;
        put_be64(delta_metadata + 1, 2);
        put_be64(delta_metadata + 9, 1);
        uint64_t delta_checksum = 0;
        for (uint32_t tile_index = 0; tile_index < 16u; tile_index++) {
            delta_checksum ^= tb_bc7_tile_checksum(
                blocks + (size_t)tile_index * 256u,
                4096,
                16,
                tile_index
            );
        }
        put_be64(delta_metadata + 17, delta_checksum);
        put_be32(delta_metadata + 25, 1024);
        put_be32(delta_metadata + 29, 64);
        put_be16(delta_metadata + 33, 64);
        put_be16(delta_metadata + 35, 1);
        put_be16(delta_metadata + 37, 0);
        put_be16(delta_metadata + 39, 0);
        put_be16(delta_metadata + 41, 16);
        put_be16(delta_metadata + 43, 64);
        put_be32(delta_metadata + 45, (uint32_t)blocks_len);
        const size_t delta_wrapper_len =
            24u + sizeof(delta_metadata) + compressed_len;
        uint8_t *delta_wrapper = calloc(1, delta_wrapper_len);
        CHECK(delta_wrapper != NULL, "compressed delta wrapper allocated");
        if (delta_wrapper) {
            delta_wrapper[0] = 1;
            delta_wrapper[1] = TB_BC7_COMPRESSION_LZFSE;
            delta_wrapper[2] = TB_BC7_TRANSFORM_BYTE_PLANES;
            put_be32(delta_wrapper + 4, (uint32_t)sizeof(delta_metadata));
            put_be32(delta_wrapper + 8, (uint32_t)blocks_len);
            put_be32(delta_wrapper + 12, (uint32_t)compressed_len);
            put_be64(
                delta_wrapper + 16,
                tb_bc7_supercompression_checksum(compressed, compressed_len)
            );
            memcpy(delta_wrapper + 24, delta_metadata, sizeof(delta_metadata));
            memcpy(
                delta_wrapper + 24 + sizeof(delta_metadata),
                compressed,
                compressed_len
            );
            CHECK(tb_bc7_supercompression_decode_delta(
                      delta_wrapper, delta_wrapper_len, &result) == 0,
                  "compressed BC7 delta decodes");
            struct tb_bc7_delta_frame delta_frame;
            CHECK(tb_bc7_delta_parse(
                      result.payload, result.payload_len, &delta_frame) == 0,
                  "decoded compressed delta reconstructs legacy payload");
            CHECK(delta_frame.run_count == 1 &&
                  delta_frame.runs[0].data_length == blocks_len,
                  "decoded compressed delta run preserved");
            CHECK(memcmp(delta_frame.runs[0].data, blocks, blocks_len) == 0,
                  "decoded compressed delta blocks preserved");
            uint8_t shadow[64u * 1024u] = {0};
            uint64_t tile_checksums[16] = {0};
            uint64_t applied_checksum = 0;
            CHECK(tb_bc7_delta_apply_to_shadow(
                      &delta_frame,
                      shadow,
                      sizeof(shadow),
                      4096,
                      tile_checksums,
                      16,
                      &applied_checksum) == 0,
                  "reconstructed compressed delta passes legacy checksum guard");
            CHECK(applied_checksum == delta_checksum,
                  "reconstructed compressed delta checksum preserved");
            result.payload[17] ^= 1u;
            CHECK(tb_bc7_delta_parse(
                      result.payload, result.payload_len, &delta_frame) == 0,
                  "checksum-mutated reconstructed delta still parses");
            memset(shadow, 0, sizeof(shadow));
            memset(tile_checksums, 0, sizeof(tile_checksums));
            CHECK(tb_bc7_delta_apply_to_shadow(
                      &delta_frame,
                      shadow,
                      sizeof(shadow),
                      4096,
                      tile_checksums,
                      16,
                      &applied_checksum) == -1,
                  "legacy checksum guard rejects corrupted reconstructed delta");
            CHECK(shadow[0] == 0,
                  "rejected reconstructed delta does not mutate live shadow");
            tb_bc7_supercompression_result_free(&result);
            put_be16(delta_wrapper + 24 + 35, 257);
            CHECK(tb_bc7_supercompression_decode_delta(
                      delta_wrapper, delta_wrapper_len, &result) == -1,
                  "compressed delta run count above protocol limit rejected");
            free(delta_wrapper);
        }

        free(wrapper);
        free(blocks);
        free(planes);
        free(compressed);
    }
    CHECK(!tb_bc7_delta_prefers_full_upload(&frame, 1u << 20),
          "many tiny runs stay as regional uploads");
    for (uint16_t index = 0; index < frame.run_count; index++) {
        frame.runs[index].data_length = 128;
    }
    CHECK(tb_bc7_delta_prefers_full_upload(&frame, 16384),
          "many substantial runs collapse to one full texture upload");
    frame.run_count = 1;
    frame.runs[0].data_length = 4096;
    CHECK(tb_bc7_delta_prefers_full_upload(&frame, 16384),
          "large changed payload uses one full texture upload");
    memset(shadow, 0, sizeof(shadow));
    tile_checksums[0] = 0;
    frame.checksum ^= 1u;
    CHECK(tb_bc7_delta_apply_to_shadow(
              &frame, shadow, sizeof(shadow), 256,
              tile_checksums, 1, &applied_checksum) == -1,
          "content checksum mismatch rejected before live-state commit");
    frame.checksum ^= 1u;

    put_be32(payload + 45, (uint32_t)run_len - 1);
    CHECK(tb_bc7_delta_parse(payload, 49 + run_len, &frame) == -1,
          "delta data length mismatch rejected");
    put_be32(payload + 45, (uint32_t)run_len);
    put_be16(payload + 41, 2);
    CHECK(tb_bc7_delta_parse(payload, 49 + run_len, &frame) == -1,
          "delta run outside tile grid rejected");
    put_be16(payload + 41, 1);
    CHECK(tb_bc7_delta_parse(payload, 48 + run_len, &frame) == -1,
          "truncated delta rejected");
    free(payload);

    uint8_t zero_run[37] = {0};
    zero_run[0] = 1;
    put_be64(zero_run + 1, 3);
    put_be64(zero_run + 9, 2);
    put_be32(zero_run + 25, 64);
    put_be32(zero_run + 29, 64);
    put_be16(zero_run + 33, 64);
    CHECK(tb_bc7_delta_parse(zero_run, sizeof(zero_run), &frame) == 0,
          "zero-run liveness delta accepted");
    CHECK(tb_bc7_delta_sequence_valid(3, 2, 2),
          "next delta sequence accepted");
    CHECK(!tb_bc7_delta_sequence_valid(4, 2, 2),
          "skipped delta sequence rejected");
    CHECK(!tb_bc7_delta_sequence_valid(3, 2, 1),
          "stale delta base rejected");

    uint8_t tile[4096];
    memset(tile, 0x11, sizeof(tile));
    CHECK(tb_bc7_tile_checksum(tile, 256, 16, 0) ==
              UINT64_C(0x2da531699a697325),
          "tile checksum matches cross-language fixture");
}

static void test_bc7_cursor_policy(void) {
    CHECK(tb_bc7_cursor_normalize_type(0) == 0, "arrow cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(1) == 1, "I-beam cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(2) == 2, "hand cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(3) == 3, "horizontal resize cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(4) == 4, "vertical resize cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(6) == 6, "crosshair cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(7) == 7, "NWSE cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(8) == 8, "NESW cursor preserved");
    CHECK(tb_bc7_cursor_normalize_type(99) == 0, "unknown cursor falls back to arrow");

    CHECK(tb_bc7_cursor_size_for_drawable_width(4999.0f) == 44.0f,
          "normal drawable uses 44-pixel cursor");
    CHECK(tb_bc7_cursor_size_for_drawable_width(5000.0f) == 58.0f,
          "5K drawable uses 58-pixel cursor");

    CHECK(!tb_bc7_cursor_should_redraw(1040u, 1000u),
          "cursor update at 40ms waits for next video frame");
    CHECK(tb_bc7_cursor_should_redraw(1041u, 1000u),
          "stale video redraws cursor after 40ms");
    CHECK(tb_bc7_cursor_should_redraw(5u, UINT32_MAX - 40u),
          "redraw throttle handles tick wraparound");
}

int main(void) {
    test_single_packet_whole_feed();
    test_byte_by_byte_feed();
    test_two_contiguous_packets();
    test_split_across_feeds_with_remainder();
    test_zero_length_is_fatal();
    test_oversized_length_is_fatal();
    test_large_payload_roundtrip();
    test_bc7_packet_type();
    test_bc7_payload_validation();
    test_bc7_sequenced_keyframe_validation();
    test_bc7_delta_validation();
    test_bc7_cursor_policy();

    if (g_failures == 0) {
        printf("net parser tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "net parser tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
