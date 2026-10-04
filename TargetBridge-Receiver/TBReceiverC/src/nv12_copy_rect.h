#ifndef TB_NV12_COPY_RECT_H
#define TB_NV12_COPY_RECT_H

#include <stddef.h>
#include <stdint.h>

#include "nv12_tile_runs.h"

/* Format 5: tile runs copied from the previous frame by one shared vector,
 * plus fresh tile runs laid out exactly as in format 4.
 *
 * Header (40 bytes, big endian):
 *   [0] format=5 [1] compression=1(LZ4) [2..3] tile size=64
 *   [4] width [8] height [12] fresh run count [16] raw length
 *   [20] compressed length [24] checksum (u64)
 *   [32] dx (s16) [34] dy (s16) [36] copy run count
 * Then copy descriptors (8 bytes: tile_x, tile_y, tile_count_x, reserved=0),
 * fresh descriptors (16 bytes, format 4 layout) and the LZ4 stream. With no
 * fresh runs, the raw and compressed lengths are zero and no stream follows.
 *
 * A copied tile at (x, y) takes the previous frame's pixels at (x-dx, y-dy).
 * Copies read the previous frame as a snapshot; fresh runs apply after. */
#define TB_NV12_COPY_RECT_FORMAT 5u
#define TB_NV12_COPY_RECT_HEADER_BYTES 40u
#define TB_NV12_COPY_RECT_COPY_DESCRIPTOR_BYTES 8u
#define TB_NV12_COPY_RECT_MAX_TILES_PER_SIDE \
    (8192u / TB_NV12_TILE_RUN_SIZE)

struct tb_nv12_copy_run {
    uint16_t tile_x;
    uint16_t tile_y;
    uint16_t tile_count_x;
};

struct tb_nv12_copy_rect_frame {
    uint32_t width;
    uint32_t height;
    int32_t dx;
    int32_t dy;
    uint32_t copy_count;
    uint32_t fresh_count;
    uint32_t raw_length;
    uint32_t compressed_length;
    uint64_t checksum;
    /* NULL when the frame carries no fresh runs. */
    const uint8_t *compressed;
};

/* A rectangle of a frame, in pixels. */
struct tb_nv12_rect {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
};

/* Validates a format 5 payload. Copy and fresh runs must each be in row-major
 * order, must not overlap one another, and every copy source must lie inside
 * the frame. Returns 0 on success, -1 on malformed input. */
int tb_nv12_copy_rect_parse(
    const uint8_t *payload,
    size_t payload_length,
    struct tb_nv12_copy_rect_frame *frame,
    struct tb_nv12_copy_run *copies,
    size_t copy_capacity,
    struct tb_nv12_tile_run *fresh,
    size_t fresh_capacity);

/* Applies a parsed frame's copies in place. Rows and runs are visited in an
 * order that never reads a pixel this call has already overwritten. */
void tb_nv12_copy_rect_apply_copies(
    const struct tb_nv12_copy_rect_frame *frame,
    const struct tb_nv12_copy_run *copies,
    uint8_t *y_plane,
    size_t y_stride,
    uint8_t *uv_plane,
    size_t uv_stride);

/* Writes decoded format 4/5 tile-run data into NV12 planes. */
void tb_nv12_tile_runs_write(
    const struct tb_nv12_tile_run *runs,
    uint32_t run_count,
    const uint8_t *raw,
    uint8_t *y_plane,
    size_t y_stride,
    uint8_t *uv_plane,
    size_t uv_stride);

/* Rectangles covering every copied and fresh tile: per tile row, the span
 * from the leftmost to the rightmost touched tile, with vertically adjacent
 * rows of the same span merged. Returns the rectangle count; `rects` needs
 * room for one rectangle per tile row. */
size_t tb_nv12_copy_rect_dirty_rects(
    const struct tb_nv12_copy_rect_frame *frame,
    const struct tb_nv12_copy_run *copies,
    const struct tb_nv12_tile_run *fresh,
    struct tb_nv12_rect *rects,
    size_t rect_capacity);

#endif
