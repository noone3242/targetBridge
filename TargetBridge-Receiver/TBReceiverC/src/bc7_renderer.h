#ifndef TB_BC7_RENDERER_H
#define TB_BC7_RENDERER_H

#include <stddef.h>
#include <stdint.h>

#include "bc7_adaptive.h"

struct SDL_Window;
struct tb_bc7_renderer;

#ifdef __cplusplus
extern "C" {
#endif

int tb_bc7_renderer_supported(void);
int tb_bc7_renderer_copy_device_name(char *buffer, size_t buffer_size);

struct tb_bc7_renderer *tb_bc7_renderer_create(struct SDL_Window *window);
void tb_bc7_renderer_destroy(struct tb_bc7_renderer *renderer);
void tb_bc7_renderer_set_visible(struct tb_bc7_renderer *renderer, int visible);

int tb_bc7_renderer_render(struct tb_bc7_renderer *renderer,
                           const uint8_t *blocks,
                           size_t length,
                           uint32_t width,
                           uint32_t height,
                           uint32_t bytes_per_row,
                           int wait_for_completion);
int tb_bc7_renderer_upload(struct tb_bc7_renderer *renderer,
                           const uint8_t *blocks,
                           size_t length,
                           uint32_t width,
                           uint32_t height,
                           uint32_t bytes_per_row);
int tb_bc7_renderer_upload_region(struct tb_bc7_renderer *renderer,
                                  const uint8_t *blocks,
                                  size_t length,
                                  uint32_t texture_width,
                                  uint32_t texture_height,
                                  uint32_t x,
                                  uint32_t y,
                                  uint32_t width,
                                  uint32_t height,
                                  uint32_t bytes_per_row);
int tb_bc7_renderer_present(struct tb_bc7_renderer *renderer,
                            int wait_for_completion);
int tb_bc7_renderer_apply_adaptive(
    struct tb_bc7_renderer *renderer,
    const struct tb_bc7_adaptive_frame *frame,
    int wait_for_completion);

void tb_bc7_renderer_set_cursor(struct tb_bc7_renderer *renderer,
                                int x,
                                int y,
                                int source_width,
                                int source_height,
                                int visible,
                                int type);
void tb_bc7_renderer_redraw(struct tb_bc7_renderer *renderer);

#ifdef __cplusplus
}
#endif

#endif
