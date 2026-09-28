#ifndef TB_WINDOW_POLICY_H
#define TB_WINDOW_POLICY_H

#include <stdint.h>

#define TB_WINDOW_CLOSE_QUIT_SUPPRESSION_MS 750u

static inline int tb_window_should_honor_quit(uint32_t now,
                                              uint32_t last_window_close_tick) {
    if (last_window_close_tick == 0) return 1;
    return (uint32_t)(now - last_window_close_tick) >
           TB_WINDOW_CLOSE_QUIT_SUPPRESSION_MS;
}

#endif
