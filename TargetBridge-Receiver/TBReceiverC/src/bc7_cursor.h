#ifndef TB_BC7_CURSOR_H
#define TB_BC7_CURSOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int tb_bc7_cursor_normalize_type(int type);
float tb_bc7_cursor_size_for_drawable_width(float drawable_width);
int tb_bc7_cursor_should_redraw(uint32_t now, uint32_t last_video_frame_time);

#ifdef __cplusplus
}
#endif

#endif
