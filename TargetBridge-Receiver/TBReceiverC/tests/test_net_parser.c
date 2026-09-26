/* test_net_parser.c — hardware-free unit tests for the streaming packet
 * parser in net.c (the framing layer every receiver session depends on).
 *
 * Build & run:  make test
 *
 * Only needs net.c + POSIX — no ffmpeg, no SDL, no Thunderbolt. */

#include "../src/net.h"
#include "../src/proto.h"
#include "../src/bc7_frame.h"
#include "../src/bc7_cursor.h"

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

    payload[0] = 2;
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
    test_bc7_cursor_policy();

    if (g_failures == 0) {
        printf("net parser tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "net parser tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
