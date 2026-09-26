#include "bc7_cursor.h"

int tb_bc7_cursor_normalize_type(int type) {
    switch (type) {
    case 1:
    case 2:
    case 3:
    case 4:
    case 6:
    case 7:
    case 8:
        return type;
    default:
        return 0;
    }
}

float tb_bc7_cursor_size_for_drawable_width(float drawable_width) {
    return drawable_width >= 5000.0f ? 58.0f : 44.0f;
}

int tb_bc7_cursor_should_redraw(uint32_t now, uint32_t last_video_frame_time) {
    return (uint32_t)(now - last_video_frame_time) > 40u;
}
