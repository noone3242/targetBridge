#ifndef TB_IDLE_POLICY_H
#define TB_IDLE_POLICY_H

#include <stddef.h>
#include <stdint.h>

#define TB_RECEIVER_DISCONNECTED_DELAY_MS 16u
#define TB_RECEIVER_CONNECTING_DELAY_MS 1u
#define TB_RECEIVER_ACTIVE_IDLE_DELAY_MS 1u

static inline uint32_t tb_receiver_loop_delay_ms(int client_connected,
                                                 int have_video_frame,
                                                 int socket_activity) {
    if (!client_connected) return TB_RECEIVER_DISCONNECTED_DELAY_MS;
    if (!have_video_frame) return TB_RECEIVER_CONNECTING_DELAY_MS;
    if (socket_activity == 0) return TB_RECEIVER_ACTIVE_IDLE_DELAY_MS;
    return 0;
}

static inline int tb_receiver_status_should_present(int content_changed,
                                                    int ui_visible) {
    return content_changed || !ui_visible;
}

static inline int tb_receiver_audio_should_start(int audio_playing,
                                                 size_t payload_bytes) {
    return !audio_playing && payload_bytes > 0;
}

static inline int tb_receiver_audio_should_pause(int client_connected,
                                                 int audio_playing) {
    return !client_connected && audio_playing;
}

#endif
