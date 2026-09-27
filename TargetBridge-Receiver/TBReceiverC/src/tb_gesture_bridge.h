#ifndef TB_GESTURE_BRIDGE_H
#define TB_GESTURE_BRIDGE_H

typedef void (*tb_gesture_space_switch_callback)(int direction, void *context);

void tb_gesture_bridge_install(tb_gesture_space_switch_callback callback, void *context);
void tb_gesture_bridge_set_active(int active);

/* Returns 1 if the given SDL_Window's Cocoa window is on the active macOS
 * Space (or can't be determined), 0 if it is on a different Space. */
int tb_window_on_active_space(void *sdl_window);

/* Native AppKit status overlay used while no stream is being presented. */
void tb_native_status_show(void *sdl_window,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions,
                           int connecting,
                           const char *connecting_text,
                           const char *waiting_text);
void tb_native_status_hide(void);
void tb_native_status_destroy(void);

#endif
