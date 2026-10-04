#include "nv12_copy_rect.h"

#include <limits.h>
#include <string.h>

#define TB_NV12_COPY_RECT_MAX_BYTES (64u * 1024u * 1024u)
#define TB_NV12_COPY_RECT_MAX_TILES                \
    (TB_NV12_COPY_RECT_MAX_TILES_PER_SIDE *        \
     TB_NV12_COPY_RECT_MAX_TILES_PER_SIDE)

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

/* Marks a run's tiles as covered; fails if any tile was already covered. */
static int cover_tiles(uint8_t *covered,
                       uint32_t tiles_wide,
                       uint32_t tile_x,
                       uint32_t tile_y,
                       uint32_t tile_count_x) {
    for (uint32_t x = tile_x; x < tile_x + tile_count_x; x++) {
        const uint32_t index = tile_y * tiles_wide + x;
        const uint8_t bit = (uint8_t)(1u << (index & 7u));
        if (covered[index >> 3] & bit) return -1;
        covered[index >> 3] |= bit;
    }
    return 0;
}

int tb_nv12_copy_rect_parse(
    const uint8_t *payload,
    size_t payload_length,
    struct tb_nv12_copy_rect_frame *frame,
    struct tb_nv12_copy_run *copies,
    size_t copy_capacity,
    struct tb_nv12_tile_run *fresh,
    size_t fresh_capacity) {
    if (!payload || !frame || !copies || !fresh ||
        payload_length < TB_NV12_COPY_RECT_HEADER_BYTES ||
        payload[0] != TB_NV12_COPY_RECT_FORMAT ||
        payload[1] != TB_NV12_TILE_RUN_COMPRESSION_LZ4 ||
        read_be16(payload + 2) != TB_NV12_TILE_RUN_SIZE) {
        return -1;
    }

    const uint32_t width = read_be32(payload + 4);
    const uint32_t height = read_be32(payload + 8);
    const uint32_t fresh_count = read_be32(payload + 12);
    const uint32_t raw_length = read_be32(payload + 16);
    const uint32_t compressed_length = read_be32(payload + 20);
    const uint64_t checksum = read_be64(payload + 24);
    const int32_t dx = (int16_t)read_be16(payload + 32);
    const int32_t dy = (int16_t)read_be16(payload + 34);
    const uint32_t copy_count = read_be32(payload + 36);
    if (width == 0 || height == 0 || width > 8192u || height > 8192u ||
        width % TB_NV12_TILE_RUN_SIZE != 0 ||
        height % TB_NV12_TILE_RUN_SIZE != 0 ||
        (dx & 1) || (dy & 1) || (dx == 0 && dy == 0) ||
        copy_count == 0 || copy_count > TB_NV12_TILE_RUN_MAX_RUNS ||
        copy_count > copy_capacity ||
        fresh_count > TB_NV12_TILE_RUN_MAX_RUNS ||
        fresh_count > fresh_capacity ||
        (fresh_count == 0) != (raw_length == 0) ||
        (raw_length == 0) != (compressed_length == 0) ||
        raw_length > TB_NV12_COPY_RECT_MAX_BYTES ||
        (compressed_length != 0 && compressed_length < 4u) ||
        compressed_length > TB_NV12_COPY_RECT_MAX_BYTES) {
        return -1;
    }

    const size_t copy_start = TB_NV12_COPY_RECT_HEADER_BYTES;
    const size_t fresh_start =
        copy_start +
        (size_t)copy_count * TB_NV12_COPY_RECT_COPY_DESCRIPTOR_BYTES;
    const size_t compressed_start =
        fresh_start + (size_t)fresh_count * TB_NV12_TILE_RUN_DESCRIPTOR_BYTES;
    if (compressed_start > payload_length ||
        compressed_length != payload_length - compressed_start) {
        return -1;
    }
    const uint8_t *compressed =
        compressed_length ? payload + compressed_start : NULL;
    if (compressed &&
        (compressed[compressed_length - 4u] != 0x62u ||
         compressed[compressed_length - 3u] != 0x76u ||
         compressed[compressed_length - 2u] != 0x34u ||
         compressed[compressed_length - 1u] != 0x24u)) {
        return -1;
    }

    const uint32_t tiles_wide = width / TB_NV12_TILE_RUN_SIZE;
    const uint32_t tiles_high = height / TB_NV12_TILE_RUN_SIZE;
    uint8_t covered[TB_NV12_COPY_RECT_MAX_TILES / 8u];
    memset(covered, 0, sizeof(covered));

    uint32_t previous_tile_y = UINT32_MAX;
    uint32_t previous_tile_end_x = 0;
    for (uint32_t index = 0; index < copy_count; index++) {
        const uint8_t *descriptor =
            payload + copy_start +
            (size_t)index * TB_NV12_COPY_RECT_COPY_DESCRIPTOR_BYTES;
        const struct tb_nv12_copy_run run = {
            .tile_x = read_be16(descriptor),
            .tile_y = read_be16(descriptor + 2),
            .tile_count_x = read_be16(descriptor + 4)
        };
        const int64_t x = (int64_t)run.tile_x * TB_NV12_TILE_RUN_SIZE;
        const int64_t y = (int64_t)run.tile_y * TB_NV12_TILE_RUN_SIZE;
        const int64_t pixel_width =
            (int64_t)run.tile_count_x * TB_NV12_TILE_RUN_SIZE;
        if (read_be16(descriptor + 6) != 0 ||
            run.tile_count_x == 0 ||
            run.tile_y >= tiles_high ||
            (uint32_t)run.tile_x + run.tile_count_x > tiles_wide ||
            x - dx < 0 || y - dy < 0 ||
            x + pixel_width - dx > (int64_t)width ||
            y + TB_NV12_TILE_RUN_SIZE - dy > (int64_t)height ||
            (previous_tile_y != UINT32_MAX &&
             (run.tile_y < previous_tile_y ||
              (run.tile_y == previous_tile_y &&
               run.tile_x < previous_tile_end_x))) ||
            cover_tiles(covered, tiles_wide, run.tile_x, run.tile_y,
                        run.tile_count_x) != 0) {
            return -1;
        }
        copies[index] = run;
        previous_tile_y = run.tile_y;
        previous_tile_end_x = (uint32_t)run.tile_x + run.tile_count_x;
    }

    uint32_t expected_offset = 0;
    previous_tile_y = UINT32_MAX;
    previous_tile_end_x = 0;
    for (uint32_t index = 0; index < fresh_count; index++) {
        const uint8_t *descriptor =
            payload + fresh_start +
            (size_t)index * TB_NV12_TILE_RUN_DESCRIPTOR_BYTES;
        const struct tb_nv12_tile_run run = {
            .tile_x = read_be16(descriptor),
            .tile_y = read_be16(descriptor + 2),
            .tile_count_x = read_be16(descriptor + 4),
            .pixel_height = read_be16(descriptor + 6),
            .data_offset = read_be32(descriptor + 8),
            .data_length = read_be32(descriptor + 12)
        };
        const uint64_t expected_length =
            (uint64_t)run.tile_count_x * TB_NV12_TILE_RUN_SIZE *
            TB_NV12_TILE_RUN_SIZE * 3u / 2u;
        if (run.tile_count_x == 0 ||
            run.tile_y >= tiles_high ||
            (uint32_t)run.tile_x + run.tile_count_x > tiles_wide ||
            run.pixel_height != TB_NV12_TILE_RUN_SIZE ||
            run.data_offset != expected_offset ||
            run.data_length != expected_length ||
            run.data_length > raw_length - run.data_offset ||
            (previous_tile_y != UINT32_MAX &&
             (run.tile_y < previous_tile_y ||
              (run.tile_y == previous_tile_y &&
               run.tile_x < previous_tile_end_x))) ||
            cover_tiles(covered, tiles_wide, run.tile_x, run.tile_y,
                        run.tile_count_x) != 0) {
            return -1;
        }
        fresh[index] = run;
        expected_offset += run.data_length;
        previous_tile_y = run.tile_y;
        previous_tile_end_x = (uint32_t)run.tile_x + run.tile_count_x;
    }
    if (expected_offset != raw_length) return -1;

    frame->width = width;
    frame->height = height;
    frame->dx = dx;
    frame->dy = dy;
    frame->copy_count = copy_count;
    frame->fresh_count = fresh_count;
    frame->raw_length = raw_length;
    frame->compressed_length = compressed_length;
    frame->checksum = checksum;
    frame->compressed = compressed;
    return 0;
}

/* Copies `row_count` rows of one tile row's runs within a plane. Rows that
 * the shift reads from are always visited before rows that overwrite them:
 * bottom-up when content moves down, and right-to-left within a row when it
 * moves right along the same row. */
static void copy_plane_rows(const struct tb_nv12_copy_run *runs,
                            uint32_t run_count,
                            uint8_t *plane,
                            size_t stride,
                            size_t first_row,
                            uint32_t row_count,
                            int32_t dx,
                            int32_t dy) {
    const int bottom_up = dy > 0;
    const int right_to_left = dy == 0 && dx > 0;
    for (uint32_t step = 0; step < row_count; step++) {
        const size_t row =
            first_row + (bottom_up ? row_count - 1u - step : step);
        uint8_t *destination_row = plane + row * stride;
        const uint8_t *source_row =
            plane + (size_t)((ptrdiff_t)row - dy) * stride;
        for (uint32_t index = 0; index < run_count; index++) {
            const struct tb_nv12_copy_run *run =
                &runs[right_to_left ? run_count - 1u - index : index];
            const size_t x = (size_t)run->tile_x * TB_NV12_TILE_RUN_SIZE;
            const size_t width =
                (size_t)run->tile_count_x * TB_NV12_TILE_RUN_SIZE;
            memmove(destination_row + x,
                    source_row + (ptrdiff_t)x - dx,
                    width);
        }
    }
}

static void copy_tile_row(const struct tb_nv12_copy_run *runs,
                          uint32_t run_count,
                          int32_t dx,
                          int32_t dy,
                          uint8_t *y_plane,
                          size_t y_stride,
                          uint8_t *uv_plane,
                          size_t uv_stride) {
    const size_t tile_y = runs[0].tile_y;
    copy_plane_rows(runs, run_count, y_plane, y_stride,
                    tile_y * TB_NV12_TILE_RUN_SIZE,
                    TB_NV12_TILE_RUN_SIZE, dx, dy);
    /* Interleaved CbCr: one row per two luma rows, two bytes per two
     * pixels, so the byte shift equals the even pixel shift. */
    copy_plane_rows(runs, run_count, uv_plane, uv_stride,
                    tile_y * (TB_NV12_TILE_RUN_SIZE / 2u),
                    TB_NV12_TILE_RUN_SIZE / 2u, dx, dy / 2);
}

void tb_nv12_copy_rect_apply_copies(
    const struct tb_nv12_copy_rect_frame *frame,
    const struct tb_nv12_copy_run *copies,
    uint8_t *y_plane,
    size_t y_stride,
    uint8_t *uv_plane,
    size_t uv_stride) {
    const uint32_t count = frame->copy_count;
    if (frame->dy > 0) {
        uint32_t end = count;
        while (end > 0) {
            uint32_t begin = end - 1u;
            while (begin > 0 &&
                   copies[begin - 1u].tile_y == copies[end - 1u].tile_y) {
                begin--;
            }
            copy_tile_row(copies + begin, end - begin, frame->dx, frame->dy,
                          y_plane, y_stride, uv_plane, uv_stride);
            end = begin;
        }
        return;
    }
    uint32_t begin = 0;
    while (begin < count) {
        uint32_t end = begin + 1u;
        while (end < count && copies[end].tile_y == copies[begin].tile_y) {
            end++;
        }
        copy_tile_row(copies + begin, end - begin, frame->dx, frame->dy,
                      y_plane, y_stride, uv_plane, uv_stride);
        begin = end;
    }
}

void tb_nv12_tile_runs_write(
    const struct tb_nv12_tile_run *runs,
    uint32_t run_count,
    const uint8_t *raw,
    uint8_t *y_plane,
    size_t y_stride,
    uint8_t *uv_plane,
    size_t uv_stride) {
    for (uint32_t index = 0; index < run_count; index++) {
        const struct tb_nv12_tile_run *run = &runs[index];
        const size_t width = (size_t)run->tile_count_x * TB_NV12_TILE_RUN_SIZE;
        const size_t x = (size_t)run->tile_x * TB_NV12_TILE_RUN_SIZE;
        const size_t y = (size_t)run->tile_y * TB_NV12_TILE_RUN_SIZE;
        const uint8_t *source_y = raw + run->data_offset;
        const uint8_t *source_uv = source_y + width * run->pixel_height;
        for (size_t row = 0; row < run->pixel_height; row++) {
            memcpy(y_plane + (y + row) * y_stride + x,
                   source_y + row * width, width);
        }
        for (size_t row = 0; row < run->pixel_height / 2u; row++) {
            memcpy(uv_plane + (y / 2u + row) * uv_stride + x,
                   source_uv + row * width, width);
        }
    }
}

size_t tb_nv12_copy_rect_dirty_rects(
    const struct tb_nv12_copy_rect_frame *frame,
    const struct tb_nv12_copy_run *copies,
    const struct tb_nv12_tile_run *fresh,
    struct tb_nv12_rect *rects,
    size_t rect_capacity) {
    const uint32_t tiles_high = frame->height / TB_NV12_TILE_RUN_SIZE;
    uint16_t start_x[TB_NV12_COPY_RECT_MAX_TILES_PER_SIDE];
    uint16_t end_x[TB_NV12_COPY_RECT_MAX_TILES_PER_SIDE];
    for (uint32_t row = 0; row < tiles_high; row++) {
        start_x[row] = UINT16_MAX;
        end_x[row] = 0;
    }
    for (uint32_t index = 0; index < frame->copy_count; index++) {
        const struct tb_nv12_copy_run *run = &copies[index];
        const uint16_t run_end = (uint16_t)(run->tile_x + run->tile_count_x);
        if (run->tile_x < start_x[run->tile_y]) start_x[run->tile_y] = run->tile_x;
        if (run_end > end_x[run->tile_y]) end_x[run->tile_y] = run_end;
    }
    for (uint32_t index = 0; index < frame->fresh_count; index++) {
        const struct tb_nv12_tile_run *run = &fresh[index];
        const uint16_t run_end = (uint16_t)(run->tile_x + run->tile_count_x);
        if (run->tile_x < start_x[run->tile_y]) start_x[run->tile_y] = run->tile_x;
        if (run_end > end_x[run->tile_y]) end_x[run->tile_y] = run_end;
    }

    size_t count = 0;
    for (uint32_t row = 0; row < tiles_high; row++) {
        if (end_x[row] == 0) continue;
        const uint32_t x = (uint32_t)start_x[row] * TB_NV12_TILE_RUN_SIZE;
        const uint32_t width =
            (uint32_t)(end_x[row] - start_x[row]) * TB_NV12_TILE_RUN_SIZE;
        const uint32_t y = row * TB_NV12_TILE_RUN_SIZE;
        if (count > 0) {
            struct tb_nv12_rect *last = &rects[count - 1u];
            if (last->x == x && last->width == width &&
                last->y + last->height == y) {
                last->height += TB_NV12_TILE_RUN_SIZE;
                continue;
            }
        }
        if (count == rect_capacity) return 0;
        rects[count++] = (struct tb_nv12_rect){
            .x = x, .y = y, .width = width, .height = TB_NV12_TILE_RUN_SIZE
        };
    }
    return count;
}
