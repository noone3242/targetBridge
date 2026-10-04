/* main.c — TBReceiver pure-C entry point.
 *
 * Single-threaded event loop:
 *   - SDL_PollEvent (non-blocking)  → quit detection
 *   - non-blocking socket read     → packet parser → decoder → renderer
 *   - 1ms sleep when idle           → CPU yield
 *
 * No ObjC. No Cocoa NSApplication. No autoreleasepool.
 * Crashes from objc_release/__CFAutoreleasePoolPop cannot happen here:
 * no Objective-C runtime objects are managed by us. SDL2 may use Cocoa
 * windowing internally on macOS, but with this minimal setup the OCLP-
 * triggered bug pattern (corrupt object in main-thread ARP) is dramatically
 * less likely than with SwiftUI / AppKit programmatic UIs.
 */

#include "net.h"
#include "bc7_frame.h"
#include "bc7_delta.h"
#include "bc7_supercompression.h"
#include "bc7_renderer.h"
#include "nv12_tile_runs.h"
#include "idle_policy.h"
#include "receiver_diagnostics.h"
#include "receiver_heartbeat.h"
#include "decoder.h"
#include "display.h"
#include "proto.h"
#include "tb_gesture_bridge.h"
#include "tb_i18n.h"

#include <SDL.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dns_sd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreAudio/CoreAudio.h>
#include <compression.h>

/* kAudioObjectPropertyElementMain is the macOS 12+ SDK spelling; older SDKs
 * only define kAudioObjectPropertyElementMaster (both are numerically 0). */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

#define AUDIO_BUF_CAP (192000) // 1 second buffer of 48000Hz stereo 16-bit PCM

/* Reap a connected sender that has gone completely silent. The sender
 * heartbeats every 2s and streams frames continuously, so 10s of silence
 * (5 missed heartbeats) means it died without a FIN. */
#define TB_SENDER_IDLE_TIMEOUT_MS 10000
#define TB_METRIC_WINDOW_CAP 600

struct tb_metric_window {
    uint64_t values[TB_METRIC_WINDOW_CAP];
    size_t count;
    size_t next;
};

struct tb_metric_summary {
    uint64_t p50;
    uint64_t p95;
    uint64_t p99;
    uint64_t max;
};

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;
    struct tb_parser   parser;

    int      server_fd;
    int      client_fd;

    uint64_t frames;
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    uint64_t last_presented_count;
    uint64_t received_bytes;
    uint64_t last_debug_bytes;
    uint64_t packets_received;
    uint64_t bc7_frames;
    uint64_t bc7_bytes;
    uint64_t bc7_invalid_frames;
    uint64_t bc7_render_failures;
    uint64_t bc7_ack_requests;
    uint64_t bc7_acks_sent;
    uint64_t bc7_delta_frames;
    uint64_t bc7_compressed_packets;
    uint64_t bc7_decompression_failures;
    uint64_t bc7_compressed_block_bytes;
    uint64_t bc7_raw_block_bytes;
    uint64_t bc7_keyframe_requests;
    uint64_t bc7_applied_sequence;
    uint64_t bc7_checksum;
    int raw_has_baseline;
    size_t raw_y_len, raw_uv_len;
    uint32_t raw_width, raw_height, raw_y_stride, raw_uv_stride;
    uint8_t *raw_decode_buffer;
    size_t raw_decode_capacity;
    uint64_t raw_last_keyframe_request_ms;
    int raw_keyframe_request_pending;
    uint64_t bc7_last_keyframe_request_ms;
    int bc7_keyframe_request_pending;
    uint8_t *bc7_shadow;
    uint64_t *bc7_tile_checksums;
    uint64_t *bc7_candidate_tile_checksums;
    size_t bc7_shadow_len;
    size_t bc7_tile_count;
    uint32_t bc7_width;
    uint32_t bc7_height;
    uint32_t bc7_bytes_per_row;
    uint64_t bc7_last_packet_ns;
    uint64_t bc7_last_present_ns;
    uint64_t bc7_presented_frames;
    uint64_t bc7_coalesced_frames;
    int bc7_present_pending;
    uint64_t bc7_present_retry_after_ms;
    uint32_t bc7_pending_present_width;
    uint32_t bc7_pending_present_height;
    struct tb_metric_window bc7_packet_interval_ns;
    struct tb_metric_window bc7_apply_ns;
    struct tb_metric_window bc7_upload_ns;
    struct tb_metric_window bc7_present_ns;
    struct tb_metric_window bc7_present_interval_ns;
    struct tb_metric_window bc7_decompression_ns;
    struct tb_metric_window bc7_inverse_transform_ns;
    uint64_t raw_full_frames;
    uint64_t raw_region_frames;
    uint64_t raw_tile_run_frames;
    uint64_t raw_tile_runs;
    struct tb_metric_window raw_shadow_commit_ns;
    struct tb_metric_window raw_upload_ns;
    struct tb_metric_window raw_checksum_ns;
    uint64_t last_ip_check_ms;
    uint64_t last_recv_ms;      /* idle watchdog: last time the sender sent anything */
    uint64_t last_packet_ms;
    uint64_t last_heartbeat_sequence;
    uint64_t last_persistent_metrics_ms;
    uint64_t last_loop_ms;
    uint64_t max_loop_lag_ms;
    uint8_t  last_packet_type;
    int      last_heartbeat_sequence_valid;
    int      heartbeat_ack_send_error;
    int      clock_error_logged;
    int      debug_enabled;
    int      close_requested;
    int      have_video_frame;
    int      bc7_render_ack_sent;
    uint32_t bc7_render_generation;
    /* A real streaming session has begun (the sender sent a session packet, not
     * just a transient probe like a UI-language push). Gates the fullscreen
     * "connecting" splash so a bare/short-lived connection doesn't flash it. */
    int      session_active;

    char     ip_text[64];
    char     tb_ip_text[64];
    char     net_ip_text[64];
    char     display_host[128]; /* short hostname (or hostname+IP), cached at startup */
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
    char     language_pref[8];
    char     language_text[96];
    char     permissions_text[160];
    char     sender_ui_language[8];
    char     input_control_mode[32];
    char     active_transport[16];
    int      last_input_monitoring_trusted;
    int      last_accessibility_trusted;
    uint64_t last_permissions_poll_ms;

    DNSServiceRef bonjour_ref;
    char     bonjour_name[128];
    CFMachPortRef input_tap;
    CFRunLoopSourceRef input_tap_source;
    int      input_tap_consumes_events;

    SDL_AudioDeviceID audio_device;
    int               audio_playing;

    uint8_t audio_buf[AUDIO_BUF_CAP];
    int     audio_buf_head;
    int     audio_buf_tail;
    int     audio_buf_size;

    uint64_t input_events_sent;
    uint64_t input_events_received;
    uint64_t last_target_switch_ms;
    uint64_t last_space_switch_ms;
    uint64_t last_space_gesture_ms;
    int      space_gesture_accum_x;
    int      sent_command_down;
    int      sent_shift_down;
    int      sent_option_down;
    int      sent_control_down;
    int      sent_caps_down;
    uint64_t last_clipboard_poll_ms;
    char     last_clipboard_text[4096];
    struct tb_receiver_diagnostics diagnostics;
};

static int send_all(int fd, const uint8_t *buf, size_t len);

static int tb_should_log_input_event(uint64_t count) {
    return count <= 20 || (count % 100) == 0;
}

static void tb_receiver_input_log(const char *fmt, ...) {
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    fprintf(stderr, "%s\n", message);

    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/TargetBridge Receiver/Logs", home);
    mkdir(dir, 0755);

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/input-debug.log", dir);
    FILE *f = fopen(path, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char timestamp[64];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", &tm_now);
    fprintf(f, "%s %s\n", timestamp, message);
    fclose(f);
}

static volatile sig_atomic_t g_term = 0;
static void on_sigint(int s) { (void)s; g_term = 1; }

static int g_monotonic_clock_errno = 0;
static uint64_t g_last_monotonic_ms = 0;

static uint64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        g_monotonic_clock_errno = errno;
        return g_last_monotonic_ms;
    }
    g_monotonic_clock_errno = 0;
    g_last_monotonic_ms =
        (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
    return g_last_monotonic_ms;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void metric_record(struct tb_metric_window *window, uint64_t value) {
    if (!window) return;
    if (window->count < TB_METRIC_WINDOW_CAP) {
        window->values[window->count++] = value;
        return;
    }
    window->values[window->next] = value;
    window->next = (window->next + 1u) % TB_METRIC_WINDOW_CAP;
}

static int compare_u64(const void *lhs, const void *rhs) {
    const uint64_t a = *(const uint64_t *)lhs;
    const uint64_t b = *(const uint64_t *)rhs;
    return a < b ? -1 : (a > b ? 1 : 0);
}

static struct tb_metric_summary metric_summary(
    const struct tb_metric_window *window) {
    struct tb_metric_summary summary = {0};
    if (!window || window->count == 0) return summary;
    uint64_t sorted[TB_METRIC_WINDOW_CAP];
    memcpy(sorted, window->values, window->count * sizeof(*sorted));
    qsort(sorted, window->count, sizeof(*sorted), compare_u64);
    const size_t last = window->count - 1u;
    summary.p50 = sorted[(last * 50u + 99u) / 100u];
    summary.p95 = sorted[(last * 95u + 99u) / 100u];
    summary.p99 = sorted[(last * 99u + 99u) / 100u];
    summary.max = sorted[last];
    return summary;
}

static double ns_to_ms(uint64_t value) {
    return (double)value / 1000000.0;
}

static void tb_copy_i18n(char *dest, size_t size, const char *key);
static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count);
static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec);
static void tb_refresh_idle_localized_strings(struct app *a);
static void tb_receiver_load_language_preference(char *dest, size_t size);
static void tb_receiver_save_language_preference(const char *language_pref);
static void tb_receiver_apply_language_preference(struct app *a);
static void tb_receiver_cycle_language_preference(struct app *a);
static void tb_receiver_refresh_language_text(struct app *a);
static void tb_receiver_refresh_permissions_text(struct app *a);
static void tb_receiver_poll_permissions(struct app *a);
static int tb_receiver_input_monitoring_trusted(void);
static int tb_receiver_accessibility_trusted(void);
static void send_receiver_info(struct app *a);
static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_refresh_input_capture(struct app *a);
static void tb_receiver_set_clipboard_text(const char *text);
static int tb_receiver_get_clipboard_text(char *dest, size_t size);
static void tb_receiver_send_clipboard_if_changed(struct app *a);
static void write_be32(uint8_t *dst, uint32_t value);

static int tb_receiver_is_valid_language_pref(const char *language_pref) {
    return language_pref &&
           (strcmp(language_pref, "auto") == 0 ||
            strcmp(language_pref, "it") == 0 ||
            strcmp(language_pref, "en") == 0 ||
            strcmp(language_pref, "de") == 0 ||
            strcmp(language_pref, "fr") == 0 ||
            strcmp(language_pref, "zh") == 0);
}

static void tb_receiver_settings_path(char *dest, size_t size) {
    const char *home = getenv("HOME");
    if (!dest || size == 0) return;
    dest[0] = '\0';
    if (!home || !*home) return;
    snprintf(dest, size, "%s/Library/Application Support/TargetBridge Receiver/settings.json", home);
}

static void tb_receiver_ensure_settings_dir(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge Receiver", home);
    mkdir(path, 0755);
}

static void tb_receiver_load_language_preference(char *dest, size_t size) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", "auto");

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "rb");
    if (!fp) return;

    char buf[256];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';

    const char *pos = strstr(buf, "\"language\"");
    if (!pos) return;
    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    char code[8];
    size_t i = 0;
    while (*pos && *pos != '"' && i + 1 < sizeof(code)) code[i++] = *pos++;
    code[i] = '\0';

    if (tb_receiver_is_valid_language_pref(code)) {
        snprintf(dest, size, "%s", code);
    }
}

static void tb_receiver_save_language_preference(const char *language_pref) {
    if (!tb_receiver_is_valid_language_pref(language_pref)) return;
    tb_receiver_ensure_settings_dir();

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "wb");
    if (!fp) return;
    fprintf(fp, "{\n  \"language\": \"%s\"\n}\n", language_pref);
    fclose(fp);
}

static const char *tb_receiver_language_display_name(const char *language_code) {
    if (!language_code || !*language_code) language_code = "en";
    if (strcmp(language_code, "it") == 0) return tb_i18n_get("common.language.italian");
    if (strcmp(language_code, "de") == 0) return tb_i18n_get("common.language.german");
    if (strcmp(language_code, "fr") == 0) return tb_i18n_get("common.language.french");
    if (strcmp(language_code, "zh") == 0) return tb_i18n_get("common.language.chinese");
    return tb_i18n_get("common.language.english");
}

static void tb_receiver_refresh_language_text(struct app *a) {
    if (!a) return;
    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s · %s",
                 tb_i18n_get("receiver.language.auto"),
                 tb_receiver_language_display_name(tb_i18n_current_language()));
    } else {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s",
                 tb_receiver_language_display_name(a->language_pref));
    }
}

static void tb_receiver_refresh_permissions_text(struct app *a) {
    if (!a) return;

    const int input_monitoring = (a->last_input_monitoring_trusted >= 0)
        ? a->last_input_monitoring_trusted
        : tb_receiver_input_monitoring_trusted();
    const int accessibility = (a->last_accessibility_trusted >= 0)
        ? a->last_accessibility_trusted
        : tb_receiver_accessibility_trusted();
    const char *lang = tb_i18n_current_language();

    if (lang && strncmp(lang, "it", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Monitoraggio input: %s   Accessibilità: %s",
            input_monitoring ? "OK" : "Mancante",
            accessibility ? "OK" : "Mancante"
        );
    } else if (lang && strncmp(lang, "de", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input-Monitoring: %s   Bedienungshilfen: %s",
            input_monitoring ? "OK" : "Fehlt",
            accessibility ? "OK" : "Fehlt"
        );
    } else if (lang && strncmp(lang, "zh", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "输入监控：%s   辅助功能：%s",
            input_monitoring ? "正常" : "缺失",
            accessibility ? "正常" : "缺失"
        );
    } else {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input Monitoring: %s   Accessibility: %s",
            input_monitoring ? "OK" : "Missing",
            accessibility ? "OK" : "Missing"
        );
    }
}

static void tb_receiver_poll_permissions(struct app *a) {
    if (!a) return;

    const int input_monitoring = tb_receiver_input_monitoring_trusted();
    const int accessibility = tb_receiver_accessibility_trusted();

    const int changed =
        input_monitoring != a->last_input_monitoring_trusted ||
        accessibility != a->last_accessibility_trusted;

    a->last_input_monitoring_trusted = input_monitoring;
    a->last_accessibility_trusted = accessibility;

    if (!changed) return;

    tb_receiver_refresh_permissions_text(a);
    tb_receiver_refresh_input_capture(a);
    if (a->client_fd >= 0) {
        send_receiver_info(a);
    }
    tb_receiver_input_log("[input] permission state changed inputMonitoring=%s accessibility=%s",
                          input_monitoring ? "true" : "false",
                          accessibility ? "true" : "false");
}

static void tb_receiver_apply_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        if (a->sender_ui_language[0] != '\0') {
            tb_i18n_set_runtime_language(a->sender_ui_language);
        } else {
            tb_i18n_set_runtime_language("auto");
        }
    } else {
        tb_i18n_set_runtime_language(a->language_pref);
    }

    tb_refresh_idle_localized_strings(a);
    tb_receiver_refresh_language_text(a);
    tb_receiver_refresh_permissions_text(a);
}

static int tb_receiver_input_monitoring_trusted(void) {
    return CGPreflightListenEventAccess() ? 1 : 0;
}

static int tb_receiver_accessibility_trusted(void) {
    return AXIsProcessTrusted() ? 1 : 0;
}

static void tb_receiver_cycle_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "it");
    } else if (strcmp(a->language_pref, "it") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "en");
    } else if (strcmp(a->language_pref, "en") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "de");
    } else if (strcmp(a->language_pref, "de") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "fr");
    } else if (strcmp(a->language_pref, "fr") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "zh");
    } else {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "auto");
    }

    tb_receiver_save_language_preference(a->language_pref);
    tb_receiver_apply_language_preference(a);
}

static void tb_refresh_idle_localized_strings(struct app *a) {
    if (!a) return;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.waiting_for_sender");
    tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.waiting");
    tb_copy_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.default");
    tb_receiver_refresh_permissions_text(a);
    if (a->ip_text[0] == '\0') {
        tb_copy_i18n(a->ip_text, sizeof(a->ip_text), "receiver.network.not_detected");
    }
}

static void tb_copy_i18n(char *dest, size_t size, const char *key) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", tb_i18n_get(key));
}

static void tb_json_escape_string(const char *src, char *dest, size_t size) {
    if (!dest || size == 0) return;
    if (!src) {
        dest[0] = '\0';
        return;
    }

    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < size; i++) {
        char c = src[i];
        const char *escape = NULL;
        switch (c) {
        case '\\': escape = "\\\\"; break;
        case '"': escape = "\\\""; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default: break;
        }

        if (escape) {
            for (size_t k = 0; escape[k] != '\0' && j + 1 < size; k++) {
                dest[j++] = escape[k];
            }
        } else {
            dest[j++] = c;
        }
    }
    dest[j] = '\0';
}

static void tb_receiver_set_clipboard_text(const char *text) {
    FILE *pipe = popen("pbcopy", "w");
    if (!pipe) return;
    if (text && *text) {
        fwrite(text, 1, strlen(text), pipe);
    }
    pclose(pipe);
}

static int tb_receiver_get_clipboard_text(char *dest, size_t size) {
    if (!dest || size == 0) return 0;
    dest[0] = '\0';

    FILE *pipe = popen("pbpaste", "r");
    if (!pipe) return 0;

    size_t total = 0;
    while (!feof(pipe) && total + 1 < size) {
        size_t n = fread(dest + total, 1, size - total - 1, pipe);
        total += n;
        if (n == 0) break;
    }
    dest[total] = '\0';
    pclose(pipe);
    return 1;
}

static void tb_receiver_send_clipboard_if_changed(struct app *a) {
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;

    char text[4096];
    if (!tb_receiver_get_clipboard_text(text, sizeof(text))) return;
    if (strcmp(text, a->last_clipboard_text) == 0) return;

    snprintf(a->last_clipboard_text, sizeof(a->last_clipboard_text), "%s", text);

    char escaped[8192];
    tb_json_escape_string(text, escaped, sizeof(escaped));

    char json[8300];
    int len = snprintf(json, sizeof(json), "{\"text\":\"%s\"}", escaped);
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t header[TB_HDR_BYTES];
    write_be32(header, (uint32_t)(1 + len));
    header[4] = TB_PKT_CLIPBOARD;
    if (write(a->client_fd, header, TB_HDR_BYTES) != TB_HDR_BYTES) return;
    (void)write(a->client_fd, json, (size_t)len);
}

static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count) {
    tb_i18n_format(dest, size, key, pairs, pair_count);
}

static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec) {
    char width_text[16];
    char height_text[16];
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);

    struct tb_i18n_pair pairs[] = {
        { "width", width_text },
        { "height", height_text },
        { "source", source ? source : "" },
        { "preset", preset ? preset : "" },
        { "codec", codec ? codec : "" }
    };

    if (width > 0 && height > 0 && source && *source && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_source_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset", pairs, 5);
    } else if (width > 0 && height > 0 && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_codec", pairs, 5);
    } else if (width > 0 && height > 0) {
        tb_format_i18n(dest, size, "receiver.mode.requested", pairs, 5);
    }
}

static void bonjour_deinit(struct app *a) {
    if (a->bonjour_ref) {
        DNSServiceRefDeallocate(a->bonjour_ref);
        a->bonjour_ref = NULL;
    }
}

static void on_bonjour_register(DNSServiceRef sdRef,
                                DNSServiceFlags flags,
                                DNSServiceErrorType errorCode,
                                const char *name,
                                const char *regtype,
                                const char *domain,
                                void *context) {
    (void)sdRef;
    (void)flags;
    (void)context;
    if (errorCode == kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] published %s.%s%s\n", name ? name : "TargetBridge Receiver", regtype ? regtype : "", domain ? domain : "");
    } else {
        fprintf(stderr, "[bonjour] register failed: %d\n", (int)errorCode);
    }
}

static void bonjour_update(struct app *a, uint16_t port) {
    bonjour_deinit(a);

    if (a->ip_text[0] == '\0' || strcmp(a->ip_text, tb_i18n_get("receiver.network.not_detected")) == 0) return;

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    TXTRecordSetValue(&txt, "name", (uint8_t)strlen(a->bonjour_name), a->bonjour_name);
    TXTRecordSetValue(&txt, "ip", (uint8_t)strlen(a->ip_text), a->ip_text);
    if (a->tb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "tbIP", (uint8_t)strlen(a->tb_ip_text), a->tb_ip_text);
    }
    if (a->net_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "netIP", (uint8_t)strlen(a->net_ip_text), a->net_ip_text);
    }
    TXTRecordSetValue(&txt, "panel", (uint8_t)strlen(a->panel_text), a->panel_text);
    TXTRecordSetValue(&txt, "version", (uint8_t)strlen(TB_RECEIVER_VERSION), TB_RECEIVER_VERSION);
    TXTRecordSetValue(&txt, "supportsHEVCDecode", 1, tb_dec_supports_hevc_hwdecode() ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsRawNV12", 1, "1");
    TXTRecordSetValue(&txt, "supportsRawNV12LZ4", 1, "1");
    TXTRecordSetValue(&txt, "supportsRawNV12TileRuns", 1, "1");
    TXTRecordSetValue(&txt, "supportsBC7Mode6", 1, tb_disp_supports_bc7(a->disp) ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsBC7TileDelta", 1, tb_disp_supports_bc7(a->disp) ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsBC7LZFSE", 1, tb_disp_supports_bc7(a->disp) ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsBC7LZ4", 1, tb_disp_supports_bc7(a->disp) ? "1" : "0");

    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) == 0) {
        char panel_w[16];
        char panel_h[16];
        snprintf(panel_w, sizeof(panel_w), "%u", info.active_w);
        snprintf(panel_h, sizeof(panel_h), "%u", info.active_h);
        TXTRecordSetValue(&txt, "panelWidth", (uint8_t)strlen(panel_w), panel_w);
        TXTRecordSetValue(&txt, "panelHeight", (uint8_t)strlen(panel_h), panel_h);
    }

    DNSServiceErrorType err = DNSServiceRegister(
        &a->bonjour_ref,
        0,
        0,
        a->bonjour_name,
        "_targetbridge._tcp",
        "local.",
        NULL,
        htons(port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        on_bonjour_register,
        a
    );
    TXTRecordDeallocate(&txt);

    if (err != kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] unable to publish receiver service: %d\n", (int)err);
        bonjour_deinit(a);
    }
}

static void extract_json_string_field(const uint8_t *payload,
                                      size_t len,
                                      const char *key,
                                      char *out,
                                      size_t out_size) {
    if (!payload || !key || !out || out_size == 0) return;
    out[0] = '\0';

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return;

    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    size_t i = 0;
    while ((size_t)(pos - text) < len && *pos && *pos != '"' && i + 1 < out_size) {
        if (*pos == '\\' && (size_t)(pos - text + 1) < len && pos[1] != '\0') pos++;
        out[i++] = *pos++;
    }
    out[i] = '\0';
}

static int extract_json_int_field(const uint8_t *payload,
                                  size_t len,
                                  const char *key,
                                  int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    long value = strtol(pos, &end, 10);
    if (end == pos) return 0;
    *out_value = (int)value;
    return 1;
}

static int extract_json_bool_field(const uint8_t *payload,
                                   size_t len,
                                   const char *key,
                                   int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    if (strncmp(pos, "true", 4) == 0) {
        *out_value = 1;
        return 1;
    }
    if (strncmp(pos, "false", 5) == 0) {
        *out_value = 0;
        return 1;
    }
    return extract_json_int_field(payload, len, key, out_value);
}

static int extract_json_double_field(const uint8_t *payload,
                                     size_t len,
                                     const char *key,
                                     double *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    double value = strtod(pos, &end);
    if (end == pos) return 0;
    *out_value = value;
    return 1;
}

static CGPoint tb_receiver_current_mouse_location(void) {
    CGPoint point = CGPointZero;
    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        point = CGEventGetLocation(event);
        CFRelease(event);
    }
    return point;
}

static void tb_receiver_post_mouse_move(int dx, int dy, CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGPoint target = CGPointMake(current.x + dx, current.y + dy);
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, target, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_mouse_button(CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, current, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_scroll(int scroll_x, int scroll_y) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, scroll_y, scroll_x);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_key(uint16_t key_code, int is_down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, is_down ? true : false);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len) {
    char kind[32];
    kind[0] = '\0';
    extract_json_string_field(payload, len, "\"kind\"", kind, sizeof(kind));
    if (kind[0] == '\0') return;
    tb_receiver_input_log("[input][sender->receiver] received kind=%s len=%zu", kind, len);

    if (strcmp(kind, "move") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventMouseMoved, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "leftDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventLeftMouseDragged, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "rightDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventRightMouseDragged, kCGMouseButtonRight);
        return;
    }

    if (strcmp(kind, "otherDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventOtherMouseDragged, kCGMouseButtonCenter);
        return;
    }

    if (strcmp(kind, "leftDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseDown, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "leftUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseUp, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "rightDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseDown, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "rightUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseUp, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "otherDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseDown, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "otherUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseUp, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "scroll") == 0) {
        int scroll_x = 0;
        int scroll_y = 0;
        (void)extract_json_int_field(payload, len, "\"scrollX\"", &scroll_x);
        (void)extract_json_int_field(payload, len, "\"scrollY\"", &scroll_y);
        tb_receiver_post_scroll(scroll_x, scroll_y);
        return;
    }
    if (strcmp(kind, "keyDown") == 0 || strcmp(kind, "keyUp") == 0) {
        int key_code = 0;
        if (extract_json_int_field(payload, len, "\"keyCode\"", &key_code)) {
            tb_receiver_post_key((uint16_t)key_code, strcmp(kind, "keyDown") == 0);
        }
    }
}

static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len) {
    char mode[32];
    mode[0] = '\0';
    extract_json_string_field(payload, len, "\"mode\"", mode, sizeof(mode));
    if (mode[0] == '\0') {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    } else {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "%s", mode);
    }
    tb_receiver_input_log("[input] control mode updated to %s", a->input_control_mode);
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) {
        a->sent_command_down = 0;
        a->sent_shift_down = 0;
        a->sent_option_down = 0;
        a->sent_control_down = 0;
        a->sent_caps_down = 0;
    }
    tb_receiver_refresh_input_capture(a);
}

/* ---- Callbacks: decoder → display ------------------------------------ */

static void record_bc7_packet_arrival(struct app *a, uint64_t now);
static void request_raw_keyframe(struct app *a, const char *reason);

static void on_frame(const uint8_t *y, int y_stride,
                     const uint8_t *uv, int uv_stride,
                     int w, int h, void *ud) {
    struct app *a = (struct app *)ud;
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%d", w);
        snprintf(height_text, sizeof(height_text), "%d", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    const uint64_t present_started = now_ns();
    if (tb_disp_render_nv12(a->disp, y, y_stride, uv, uv_stride, w, h) != 0) {
        a->bc7_render_failures++;
        return;
    }
    const uint64_t present_finished = now_ns();
    metric_record(&a->bc7_present_ns, present_finished - present_started);
    if (a->bc7_last_present_ns != 0 &&
        present_finished >= a->bc7_last_present_ns) {
        metric_record(
            &a->bc7_present_interval_ns,
            present_finished - a->bc7_last_present_ns
        );
    }
    a->bc7_last_present_ns = present_finished;
    a->bc7_presented_frames++;
    a->frames++;
}

/* Raw passthrough: render received NV12 planes directly, bypassing the decoder.
 * Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
 *          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)] */
static void handle_raw_frame(struct app *a, const uint8_t *p, size_t len) {
    const uint64_t apply_started = now_ns();
    record_bc7_packet_arrival(a, apply_started);
    if (len > 0 && p[0] == TB_NV12_TILE_RUN_FORMAT) {
        if (!a->raw_has_baseline) {
            request_raw_keyframe(a, "tile-runs-base");
            return;
        }
        struct tb_nv12_tile_run_frame frame;
        struct tb_nv12_tile_run runs[TB_NV12_TILE_RUN_MAX_RUNS];
        if (tb_nv12_tile_run_parse(
                p, len, &frame, runs, TB_NV12_TILE_RUN_MAX_RUNS) != 0 ||
            frame.width != a->raw_width ||
            frame.height != a->raw_height) {
            request_raw_keyframe(a, "tile-runs-format");
            return;
        }
        if (a->raw_decode_capacity < frame.raw_length) {
            uint8_t *resized = realloc(
                a->raw_decode_buffer, frame.raw_length
            );
            if (!resized) {
                request_raw_keyframe(a, "tile-runs-allocation");
                return;
            }
            a->raw_decode_buffer = resized;
            a->raw_decode_capacity = frame.raw_length;
        }
        uint8_t *raw = a->raw_decode_buffer;
        if (!raw) {
            request_raw_keyframe(a, "tile-runs-allocation");
            return;
        }
        const uint64_t decode_started = now_ns();
        const size_t decoded = compression_decode_buffer(
            raw,
            frame.raw_length,
            frame.compressed,
            frame.compressed_length,
            NULL,
            COMPRESSION_LZ4
        );
        metric_record(
            &a->bc7_decompression_ns, now_ns() - decode_started
        );
        if (decoded != frame.raw_length) {
            request_raw_keyframe(a, "tile-runs-decode");
            return;
        }
        if (frame.checksum != 0) {
            const uint64_t checksum_started = now_ns();
            const int matches = tb_checksum64_matches_optional(
                raw, frame.raw_length, frame.checksum
            );
            metric_record(
                &a->raw_checksum_ns, now_ns() - checksum_started
            );
            if (!matches) {
                request_raw_keyframe(a, "tile-runs-checksum");
                return;
            }
        }

        const uint64_t upload_started = now_ns();
        for (uint32_t index = 0; index < frame.run_count; index++) {
            const struct tb_nv12_tile_run *run = &runs[index];
            const uint32_t pixel_width =
                (uint32_t)run->tile_count_x * TB_NV12_TILE_RUN_SIZE;
            const uint32_t y_length = pixel_width * run->pixel_height;
            const uint8_t *run_y = raw + run->data_offset;
            const uint8_t *run_uv = run_y + y_length;
            if (tb_disp_update_nv12_region(
                    a->disp,
                    run_y,
                    (int)pixel_width,
                    run_uv,
                    (int)pixel_width,
                    (int)frame.width,
                    (int)frame.height,
                    (int)run->tile_x * TB_NV12_TILE_RUN_SIZE,
                    (int)run->tile_y * TB_NV12_TILE_RUN_SIZE,
                    (int)pixel_width,
                    (int)run->pixel_height) != 0) {
                request_raw_keyframe(a, "tile-runs-upload");
                return;
            }
        }
        if (tb_disp_present_nv12(a->disp) != 0) {
            request_raw_keyframe(a, "tile-runs-present");
            return;
        }
        const uint64_t upload_finished = now_ns();
        metric_record(&a->raw_shadow_commit_ns, 0);
        metric_record(
            &a->raw_upload_ns, upload_finished - upload_started
        );
        metric_record(
            &a->bc7_present_ns, upload_finished - upload_started
        );
        if (a->bc7_last_present_ns != 0) {
            metric_record(
                &a->bc7_present_interval_ns,
                upload_finished - a->bc7_last_present_ns
            );
        }
        a->bc7_last_present_ns = upload_finished;
        a->bc7_presented_frames++;
        a->raw_region_frames++;
        a->raw_tile_run_frames++;
        a->raw_tile_runs += frame.run_count;
        a->have_video_frame = 1;
        a->frames++;
        metric_record(&a->bc7_apply_ns, now_ns() - apply_started);
        return;
    }
    if (len > 0 && p[0] == 3) {
        if (len < 54 || p[1] != 1 ||
            !a->raw_has_baseline) {
            request_raw_keyframe(a, "region-base");
            return;
        }
        uint32_t v[11];
        for (int i = 0; i < 11; i++) {
            const uint8_t *q = p + 2 + i * 4;
            v[i] = ((uint32_t)q[0] << 24) | ((uint32_t)q[1] << 16) |
                   ((uint32_t)q[2] << 8) | q[3];
        }
        uint64_t checksum =
            ((uint64_t)p[46] << 56) | ((uint64_t)p[47] << 48) |
            ((uint64_t)p[48] << 40) | ((uint64_t)p[49] << 32) |
            ((uint64_t)p[50] << 24) | ((uint64_t)p[51] << 16) |
            ((uint64_t)p[52] << 8) | p[53];
        uint32_t w=v[0], h=v[1], ys=v[2], us=v[3], x=v[4], y=v[5],
                 rw=v[6], rh=v[7], ylen=v[8], uvlen=v[9], clen=v[10];
        const size_t expected_y_len = (size_t)rw * rh;
        const size_t expected_uv_len = (size_t)rw * (rh / 2u);
        if (w == 0 || h == 0 || w > 8192 || h > 8192 ||
            w != a->raw_width || h != a->raw_height ||
            ys != a->raw_y_stride || us != a->raw_uv_stride ||
            ys > 16384 || us > 16384 ||
            !rw || !rh || ((x|y|rw|rh)&1u) ||
            x > w || rw > w - x || y > h || rh > h - y ||
            ylen != expected_y_len || uvlen != expected_uv_len ||
            clen != len-54 || clen < 4 ||
            p[len-4] != 0x62 || p[len-3] != 0x76 ||
            p[len-2] != 0x34 || p[len-1] != 0x24 ||
            (size_t)(y + rh - 1u) * ys + x + rw > a->raw_y_len ||
            (size_t)(y / 2u + rh / 2u - 1u) * us + x + rw >
                a->raw_uv_len) {
            request_raw_keyframe(a, "region-geometry");
            return;
        }
        size_t raw_len=(size_t)ylen+uvlen;
        if (a->raw_decode_capacity < raw_len) {
            uint8_t *resized = realloc(a->raw_decode_buffer, raw_len);
            if (!resized) {
                request_raw_keyframe(a, "region-allocation");
                return;
            }
            a->raw_decode_buffer = resized;
            a->raw_decode_capacity = raw_len;
        }
        uint8_t *raw = a->raw_decode_buffer;
        if(!raw) {
            request_raw_keyframe(a, "region-allocation");
            return;
        }
        const uint64_t decode_started = now_ns();
        size_t decoded=compression_decode_buffer(
            raw,raw_len,p+54,clen,NULL,COMPRESSION_LZ4);
        metric_record(&a->bc7_decompression_ns, now_ns() - decode_started);
        if(decoded!=raw_len){
            request_raw_keyframe(a, "region-decode");
            return;
        }
        if(checksum!=0){
            const uint64_t checksum_started = now_ns();
            const int checksum_matches =
                tb_checksum64_matches_optional(raw,raw_len,checksum);
            metric_record(&a->raw_checksum_ns, now_ns() - checksum_started);
            if(!checksum_matches){
                request_raw_keyframe(a, "region-checksum");
                return;
            }
        }
        uint8_t *uv=raw+ylen;
        const uint64_t present_started = now_ns();
        if (tb_disp_render_nv12_region(
                a->disp, raw, (int)rw, uv, (int)rw,
                (int)w, (int)h, (int)x, (int)y, (int)rw, (int)rh) != 0) {
            request_raw_keyframe(a, "region-upload");
            return;
        }
        const uint64_t present_finished = now_ns();
        metric_record(&a->raw_shadow_commit_ns, 0);
        metric_record(&a->raw_upload_ns, present_finished - present_started);
        metric_record(&a->bc7_present_ns, present_finished - present_started);
        if (a->bc7_last_present_ns != 0) {
            metric_record(
                &a->bc7_present_interval_ns,
                present_finished - a->bc7_last_present_ns
            );
        }
        a->bc7_last_present_ns = present_finished;
        a->bc7_presented_frames++;
        a->raw_region_frames++;
        a->have_video_frame = 1;
        a->frames++;
        metric_record(&a->bc7_apply_ns, now_ns() - apply_started);
        return;
    }
    if (len >= 38 && p[0] == 2) {
        if (p[1] != 1) {
            request_raw_keyframe(a, "full-format");
            return;
        }
        uint32_t w = ((uint32_t)p[2] << 24) | ((uint32_t)p[3] << 16) |
                     ((uint32_t)p[4] << 8) | p[5];
        uint32_t h = ((uint32_t)p[6] << 24) | ((uint32_t)p[7] << 16) |
                     ((uint32_t)p[8] << 8) | p[9];
        uint32_t ys = ((uint32_t)p[10] << 24) | ((uint32_t)p[11] << 16) |
                      ((uint32_t)p[12] << 8) | p[13];
        uint32_t us = ((uint32_t)p[14] << 24) | ((uint32_t)p[15] << 16) |
                      ((uint32_t)p[16] << 8) | p[17];
        uint32_t y_size = ((uint32_t)p[18] << 24) | ((uint32_t)p[19] << 16) |
                          ((uint32_t)p[20] << 8) | p[21];
        uint32_t uv_size = ((uint32_t)p[22] << 24) | ((uint32_t)p[23] << 16) |
                           ((uint32_t)p[24] << 8) | p[25];
        uint32_t compressed_len =
            ((uint32_t)p[26] << 24) | ((uint32_t)p[27] << 16) |
            ((uint32_t)p[28] << 8) | p[29];
        uint64_t checksum =
            ((uint64_t)p[30] << 56) | ((uint64_t)p[31] << 48) |
            ((uint64_t)p[32] << 40) | ((uint64_t)p[33] << 32) |
            ((uint64_t)p[34] << 24) | ((uint64_t)p[35] << 16) |
            ((uint64_t)p[36] << 8) | p[37];
        if (w == 0 || h == 0 || (w & 1) || (h & 1) ||
            w > 8192 || h > 8192 || ys < w || us < w ||
            ys > 16384 || us > 16384 ||
            y_size != (size_t)ys * h ||
            uv_size != (size_t)us * (h / 2) ||
            (size_t)y_size + uv_size > 64u * 1024u * 1024u ||
            compressed_len != len - 38 ||
            compressed_len < 4 ||
            p[len - 4] != 0x62 || p[len - 3] != 0x76 ||
            p[len - 2] != 0x34 || p[len - 1] != 0x24) {
            request_raw_keyframe(a, "full-geometry");
            return;
        }
        size_t raw_len = (size_t)y_size + uv_size;
        if (a->raw_decode_capacity < raw_len) {
            uint8_t *resized = realloc(a->raw_decode_buffer, raw_len);
            if (!resized) {
                request_raw_keyframe(a, "full-allocation");
                return;
            }
            a->raw_decode_buffer = resized;
            a->raw_decode_capacity = raw_len;
        }
        uint8_t *raw = a->raw_decode_buffer;
        if (!raw) {
            request_raw_keyframe(a, "full-allocation");
            return;
        }
        const uint64_t decode_started = now_ns();
        size_t decoded = compression_decode_buffer(
            raw, raw_len, p + 38, compressed_len, NULL, COMPRESSION_LZ4
        );
        metric_record(&a->bc7_decompression_ns, now_ns() - decode_started);
        if (decoded != raw_len) {
            request_raw_keyframe(a, "full-decode");
            return;
        }
        if (checksum != 0) {
            const uint64_t checksum_started = now_ns();
            const int checksum_matches =
                tb_checksum64_matches_optional(raw, raw_len, checksum);
            metric_record(&a->raw_checksum_ns, now_ns() - checksum_started);
            if (!checksum_matches) {
                request_raw_keyframe(a, "full-checksum");
                return;
            }
        }
        const uint64_t upload_started = now_ns();
        if (tb_disp_render_nv12(
                a->disp, raw, (int)ys, raw + y_size, (int)us,
                (int)w, (int)h) != 0) {
            request_raw_keyframe(a, "full-upload");
            return;
        }
        const uint64_t upload_finished = now_ns();
        a->raw_has_baseline = 1;
        a->raw_y_len=y_size; a->raw_uv_len=uv_size;
        a->raw_width=w; a->raw_height=h; a->raw_y_stride=ys; a->raw_uv_stride=us;
        metric_record(&a->raw_upload_ns, upload_finished - upload_started);
        metric_record(&a->bc7_present_ns, upload_finished - upload_started);
        if (a->bc7_last_present_ns != 0) {
            metric_record(
                &a->bc7_present_interval_ns,
                upload_finished - a->bc7_last_present_ns
            );
        }
        a->bc7_last_present_ns = upload_finished;
        a->bc7_presented_frames++;
        a->have_video_frame = 1;
        a->frames++;
        a->raw_full_frames++;
        a->raw_keyframe_request_pending = 0;
        metric_record(&a->bc7_apply_ns, now_ns() - apply_started);
        return;
    }
    if (len < 17) {
        request_raw_keyframe(a, "raw-header");
        return;
    }
    if (p[0] != 1) {
        request_raw_keyframe(a, "raw-format");
        return;
    }
    uint32_t w  = ((uint32_t)p[1]  << 24) | ((uint32_t)p[2]  << 16) | ((uint32_t)p[3]  << 8) | (uint32_t)p[4];
    uint32_t h  = ((uint32_t)p[5]  << 24) | ((uint32_t)p[6]  << 16) | ((uint32_t)p[7]  << 8) | (uint32_t)p[8];
    uint32_t ys = ((uint32_t)p[9]  << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
    uint32_t us = ((uint32_t)p[13] << 24) | ((uint32_t)p[14] << 16) | ((uint32_t)p[15] << 8) | (uint32_t)p[16];
    /* Keep malformed peer data from turning into oversized stride arithmetic or
     * an out-of-bounds render. TargetBridge RAW is intentionally limited to
     * practical 4:2:0 display sizes and the protocol packet cap. */
    if (w == 0 || h == 0 || (w & 1) || (h & 1) ||
        w > 8192 || h > 8192 || ys < w || us < w ||
        ys > 16384 || us > 16384) {
        request_raw_keyframe(a, "raw-geometry");
        return;
    }
    size_t y_size  = (size_t)ys * h;
    size_t uv_size = (size_t)us * (h / 2);
    size_t payload_size = len - 17;
    if (y_size > payload_size || uv_size > payload_size - y_size) {
        request_raw_keyframe(a, "raw-length");
        return;
    }
    const uint8_t *y  = p + 17;
    const uint8_t *uv = y + y_size;
    const uint64_t upload_started = now_ns();
    if (tb_disp_render_nv12(
            a->disp, y, (int)ys, uv, (int)us, (int)w, (int)h) != 0) {
        request_raw_keyframe(a, "raw-upload");
        return;
    }
    const uint64_t upload_finished = now_ns();
    a->raw_has_baseline = 1;
    a->raw_y_len = y_size; a->raw_uv_len = uv_size;
    a->raw_width = w; a->raw_height = h;
    a->raw_y_stride = ys; a->raw_uv_stride = us;
    metric_record(&a->raw_upload_ns, upload_finished - upload_started);
    metric_record(&a->bc7_present_ns, upload_finished - upload_started);
    if (a->bc7_last_present_ns != 0) {
        metric_record(
            &a->bc7_present_interval_ns,
            upload_finished - a->bc7_last_present_ns
        );
    }
    a->bc7_last_present_ns = upload_finished;
    a->bc7_presented_frames++;
    a->raw_full_frames++;
    a->raw_keyframe_request_pending = 0;
    a->have_video_frame = 1;
    a->frames++;
    metric_record(&a->bc7_apply_ns, now_ns() - apply_started);
}

static void reset_bc7_delta_state(struct app *a) {
    free(a->bc7_shadow);
    free(a->bc7_tile_checksums);
    free(a->bc7_candidate_tile_checksums);
    a->bc7_shadow = NULL;
    a->bc7_tile_checksums = NULL;
    a->bc7_candidate_tile_checksums = NULL;
    a->bc7_shadow_len = 0;
    a->bc7_tile_count = 0;
    a->bc7_width = 0;
    a->bc7_height = 0;
    a->bc7_bytes_per_row = 0;
    a->bc7_applied_sequence = 0;
    a->bc7_checksum = 0;
    a->bc7_present_pending = 0;
    a->bc7_present_retry_after_ms = 0;
}

static void reset_raw_state(struct app *a) {
    a->raw_has_baseline = 0;
    a->raw_y_len = a->raw_uv_len = 0;
    a->raw_width = a->raw_height = 0;
    a->raw_y_stride = a->raw_uv_stride = 0;
    free(a->raw_decode_buffer);
    a->raw_decode_buffer = NULL;
    a->raw_decode_capacity = 0;
}

static uint64_t checksum_bc7_tiles(const uint8_t *blocks,
                                   uint32_t width,
                                   uint32_t height,
                                   uint32_t bytes_per_row,
                                   uint64_t *tile_checksums) {
    const uint32_t tiles_wide = width / TB_BC7_DELTA_TILE_SIZE;
    const uint32_t tiles_high =
        (height + TB_BC7_DELTA_TILE_SIZE - 1u) / TB_BC7_DELTA_TILE_SIZE;
    uint64_t checksum = 0;
    for (uint32_t tile_y = 0; tile_y < tiles_high; tile_y++) {
        const uint32_t pixel_height =
            height - tile_y * TB_BC7_DELTA_TILE_SIZE < TB_BC7_DELTA_TILE_SIZE
                ? height - tile_y * TB_BC7_DELTA_TILE_SIZE
                : TB_BC7_DELTA_TILE_SIZE;
        const uint32_t block_rows = pixel_height / 4u;
        for (uint32_t tile_x = 0; tile_x < tiles_wide; tile_x++) {
            const size_t tile_index = (size_t)tile_y * tiles_wide + tile_x;
            const size_t offset =
                (size_t)tile_y * (TB_BC7_DELTA_TILE_SIZE / 4u) * bytes_per_row +
                (size_t)tile_x * (TB_BC7_DELTA_TILE_SIZE / 4u) * 16u;
            uint64_t tile_checksum = tb_bc7_tile_checksum(
                blocks + offset,
                bytes_per_row,
                block_rows,
                (uint32_t)tile_index
            );
            tile_checksums[tile_index] = tile_checksum;
            checksum ^= tile_checksum;
        }
    }
    return checksum;
}

static void request_bc7_keyframe(struct app *a, const char *reason) {
    const uint64_t now = now_ms();
    if (a->client_fd < 0 || a->bc7_keyframe_request_pending ||
        (a->bc7_last_keyframe_request_ms != 0 &&
         now - a->bc7_last_keyframe_request_ms < 250)) {
        return;
    }

    uint8_t packet[9] = {
        0, 0, 0, 5, TB_PKT_BC7_KEYFRAME_REQUEST,
        (uint8_t)(a->bc7_render_generation >> 24),
        (uint8_t)(a->bc7_render_generation >> 16),
        (uint8_t)(a->bc7_render_generation >> 8),
        (uint8_t)a->bc7_render_generation
    };
    if (send_all(a->client_fd, packet, sizeof(packet)) == 0) {
        a->bc7_last_keyframe_request_ms = now;
        a->bc7_keyframe_request_pending = 1;
        a->bc7_keyframe_requests++;
        if (a->debug_enabled) {
            fprintf(stderr,
                    "[diag] event=bc7-keyframe-request generation=%u reason=%s count=%llu\n",
                    a->bc7_render_generation,
                    reason,
                    (unsigned long long)a->bc7_keyframe_requests);
        }
    }

}

static void request_raw_keyframe(struct app *a, const char *reason) {
    a->raw_has_baseline = 0;
    const uint64_t now = now_ms();
    if (a->client_fd < 0 || a->raw_keyframe_request_pending ||
        (a->raw_last_keyframe_request_ms != 0 &&
         now - a->raw_last_keyframe_request_ms < 250)) {
        return;
    }
    const uint8_t packet[5] = {
        0, 0, 0, 1, TB_PKT_RAW_NV12_KEYFRAME_REQUEST
    };
    if (send_all(a->client_fd, packet, sizeof(packet)) == 0) {
        a->raw_last_keyframe_request_ms = now;
        a->raw_keyframe_request_pending = 1;
        a->bc7_keyframe_requests++;
        if (a->debug_enabled) {
            fprintf(stderr,
                    "[diag] event=raw-keyframe-request reason=%s count=%llu\n",
                    reason,
                    (unsigned long long)a->bc7_keyframe_requests);
        }
    }
}

static void maybe_send_bc7_render_ack(struct app *a,
                                      uint32_t width,
                                      uint32_t height) {
    if (a->bc7_render_ack_sent || a->client_fd < 0) return;
    uint8_t packet[17] = {
        0, 0, 0, 13, TB_PKT_BC7_RENDER_ACK,
        (uint8_t)(a->bc7_render_generation >> 24),
        (uint8_t)(a->bc7_render_generation >> 16),
        (uint8_t)(a->bc7_render_generation >> 8),
        (uint8_t)a->bc7_render_generation,
        (uint8_t)(width >> 24),
        (uint8_t)(width >> 16),
        (uint8_t)(width >> 8),
        (uint8_t)width,
        (uint8_t)(height >> 24),
        (uint8_t)(height >> 16),
        (uint8_t)(height >> 8),
        (uint8_t)height
    };
    if (send_all(a->client_fd, packet, sizeof(packet)) == 0) {
        a->bc7_render_ack_sent = 1;
        a->bc7_acks_sent++;
        if (a->debug_enabled) {
            fprintf(stderr,
                    "[diag] event=bc7-render-ack generation=%u width=%u height=%u\n",
                    a->bc7_render_generation, width, height);
        }
    }
}

static void record_bc7_packet_arrival(struct app *a, uint64_t now) {
    if (a->bc7_last_packet_ns != 0 && now >= a->bc7_last_packet_ns) {
        metric_record(&a->bc7_packet_interval_ns, now - a->bc7_last_packet_ns);
    }
    a->bc7_last_packet_ns = now;
}

static void schedule_bc7_present(struct app *a,
                                 uint32_t width,
                                 uint32_t height) {
    if (a->bc7_present_pending) {
        a->bc7_coalesced_frames++;
    }
    a->bc7_present_pending = 1;
    a->bc7_present_retry_after_ms = 0;
    a->bc7_pending_present_width = width;
    a->bc7_pending_present_height = height;
}

static void present_pending_bc7(struct app *a) {
    if (!a->bc7_present_pending) return;
    const uint64_t now = now_ms();
    if (now < a->bc7_present_retry_after_ms) return;
    const uint64_t started = now_ns();
    const int wait_for_ack = !a->bc7_render_ack_sent;
    if (tb_disp_present_bc7(a->disp, wait_for_ack) != 0) {
        a->bc7_render_failures++;
        a->bc7_present_retry_after_ms = now + 8u;
        return;
    }
    const uint64_t finished = now_ns();
    metric_record(&a->bc7_present_ns, finished - started);
    if (a->bc7_last_present_ns != 0 && finished >= a->bc7_last_present_ns) {
        metric_record(
            &a->bc7_present_interval_ns,
            finished - a->bc7_last_present_ns
        );
    }
    a->bc7_last_present_ns = finished;
    a->bc7_presented_frames++;
    a->bc7_present_pending = 0;
    a->bc7_present_retry_after_ms = 0;
    maybe_send_bc7_render_ack(
        a,
        a->bc7_pending_present_width,
        a->bc7_pending_present_height
    );
}

/* Full-frame BC7 Mode 6 texture.
 * Payload: [1: format=1][BE32 w][BE32 h][BE32 bytesPerRow]
 *          [BC7 blocks: bytesPerRow*(h/4)] */
static void handle_bc7_frame(struct app *a, const uint8_t *p, size_t len) {
    const uint64_t apply_started = now_ns();
    record_bc7_packet_arrival(a, apply_started);
    struct tb_bc7_frame frame;
    if (tb_bc7_frame_parse(p, len, &frame) != 0) {
        a->bc7_invalid_frames++;
        if (a->debug_enabled) {
            fprintf(stderr, "[diag] event=bc7-invalid payloadBytes=%zu count=%llu\n",
                    len, (unsigned long long)a->bc7_invalid_frames);
        }
        return;
    }

    if (frame.format == 2) {
        if (frame.width % TB_BC7_DELTA_TILE_SIZE != 0) {
            a->bc7_invalid_frames++;
            request_bc7_keyframe(a, "keyframe-width");
            return;
        }
        const size_t tile_count =
            (size_t)(frame.width / TB_BC7_DELTA_TILE_SIZE) *
            ((frame.height + TB_BC7_DELTA_TILE_SIZE - 1u) /
             TB_BC7_DELTA_TILE_SIZE);
        uint8_t *shadow = malloc(frame.blocks_len);
        uint64_t *tile_checksums = calloc(tile_count, sizeof(*tile_checksums));
        uint64_t *candidate_tile_checksums =
            malloc(tile_count * sizeof(*candidate_tile_checksums));
        if (!shadow || !tile_checksums || !candidate_tile_checksums) {
            free(shadow);
            free(tile_checksums);
            free(candidate_tile_checksums);
            a->bc7_invalid_frames++;
            return;
        }
        memcpy(shadow, frame.blocks, frame.blocks_len);
        uint64_t checksum = checksum_bc7_tiles(
            shadow, frame.width, frame.height, frame.bytes_per_row, tile_checksums
        );
        if (checksum != frame.checksum) {
            free(shadow);
            free(tile_checksums);
            free(candidate_tile_checksums);
            a->bc7_invalid_frames++;
            request_bc7_keyframe(a, "keyframe-checksum");
            return;
        }
        const uint64_t upload_started = now_ns();
        if (tb_disp_upload_bc7(a->disp,
                               frame.blocks,
                               frame.blocks_len,
                               frame.width,
                               frame.height,
                               frame.bytes_per_row) != 0) {
            free(shadow);
            free(tile_checksums);
            free(candidate_tile_checksums);
            a->bc7_render_failures++;
            return;
        }
        metric_record(&a->bc7_upload_ns, now_ns() - upload_started);
        reset_bc7_delta_state(a);
        reset_raw_state(a);
        a->bc7_shadow = shadow;
        a->bc7_tile_checksums = tile_checksums;
        a->bc7_candidate_tile_checksums = candidate_tile_checksums;
        a->bc7_shadow_len = frame.blocks_len;
        a->bc7_tile_count = tile_count;
        a->bc7_width = frame.width;
        a->bc7_height = frame.height;
        a->bc7_bytes_per_row = frame.bytes_per_row;
        a->bc7_applied_sequence = frame.sequence;
        a->bc7_checksum = checksum;
        a->bc7_keyframe_request_pending = 0;
        a->raw_keyframe_request_pending = 0;
        a->raw_last_keyframe_request_ms = 0;
    } else {
        const uint64_t upload_started = now_ns();
        if (tb_disp_upload_bc7(a->disp,
                                  frame.blocks,
                                  frame.blocks_len,
                                  frame.width,
                                  frame.height,
                                  frame.bytes_per_row) != 0) {
            a->bc7_render_failures++;
            fprintf(stderr, "[bc7] unable to upload %ux%u frame\n",
                    frame.width, frame.height);
            return;
        }
        metric_record(&a->bc7_upload_ns, now_ns() - upload_started);
    }

    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%u", frame.width);
        snprintf(height_text, sizeof(height_text), "%u", frame.height);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    a->frames++;
    a->bc7_frames++;
    a->bc7_bytes += frame.blocks_len;
    snprintf(a->active_transport, sizeof(a->active_transport), "%s", "bc7");
    schedule_bc7_present(a, frame.width, frame.height);
    metric_record(&a->bc7_apply_ns, now_ns() - apply_started);
}

static void handle_bc7_delta(struct app *a, const uint8_t *p, size_t len) {
    const uint64_t apply_started = now_ns();
    record_bc7_packet_arrival(a, apply_started);
    struct tb_bc7_delta_frame frame;
    if (tb_bc7_delta_parse(p, len, &frame) != 0 ||
        !a->bc7_shadow || !a->bc7_tile_checksums ||
        !a->bc7_candidate_tile_checksums ||
        frame.width != a->bc7_width || frame.height != a->bc7_height ||
        !tb_bc7_delta_sequence_valid(
            frame.sequence, frame.base_sequence, a->bc7_applied_sequence
        )) {
        a->bc7_invalid_frames++;
        request_bc7_keyframe(a, "delta-base");
        return;
    }

    uint64_t checksum = 0;
    if (tb_bc7_delta_validate_candidate(
            &frame,
            a->bc7_tile_checksums,
            a->bc7_tile_count,
            a->bc7_checksum,
            a->bc7_candidate_tile_checksums,
            &checksum) != 0) {
        a->bc7_invalid_frames++;
        request_bc7_keyframe(a, "delta-checksum");
        return;
    }

    const int full_upload =
        tb_bc7_delta_prefers_full_upload(&frame, a->bc7_shadow_len);
    if (full_upload &&
        tb_bc7_delta_commit_to_shadow(
            &frame,
            a->bc7_shadow,
            a->bc7_shadow_len,
            a->bc7_bytes_per_row,
            a->bc7_tile_checksums,
            a->bc7_tile_count,
            a->bc7_candidate_tile_checksums) != 0) {
        a->bc7_invalid_frames++;
        request_bc7_keyframe(a, "delta-commit");
        return;
    }

    const uint64_t upload_started = now_ns();
    if (full_upload) {
        if (tb_disp_upload_bc7(
                a->disp,
                a->bc7_shadow,
                a->bc7_shadow_len,
                frame.width,
                frame.height,
                a->bc7_bytes_per_row) != 0) {
            a->bc7_render_failures++;
            reset_bc7_delta_state(a);
            request_bc7_keyframe(a, "delta-full-upload");
            return;
        }
    } else {
        for (uint16_t index = 0; index < frame.run_count; index++) {
            const struct tb_bc7_delta_run *run = &frame.runs[index];
            const uint32_t run_width =
                (uint32_t)run->tile_count_x * frame.tile_size;
            const uint32_t run_row_bytes = (run_width / 4u) * 16u;
            if (tb_disp_upload_bc7_region(
                    a->disp,
                    run->data,
                    run->data_length,
                    frame.width,
                    frame.height,
                    (uint32_t)run->tile_x * frame.tile_size,
                    (uint32_t)run->tile_y * frame.tile_size,
                    run_width,
                    run->pixel_height,
                    run_row_bytes) != 0) {
                a->bc7_render_failures++;
                reset_bc7_delta_state(a);
                request_bc7_keyframe(a, "delta-upload");
                return;
            }
        }
        if (tb_bc7_delta_commit_to_shadow(
                &frame,
                a->bc7_shadow,
                a->bc7_shadow_len,
                a->bc7_bytes_per_row,
                a->bc7_tile_checksums,
                a->bc7_tile_count,
                a->bc7_candidate_tile_checksums) != 0) {
            a->bc7_invalid_frames++;
            reset_bc7_delta_state(a);
            request_bc7_keyframe(a, "delta-commit");
            return;
        }
    }
    metric_record(&a->bc7_upload_ns, now_ns() - upload_started);

    a->bc7_applied_sequence = frame.sequence;
    a->bc7_checksum = checksum;
    a->frames++;
    a->bc7_frames++;
    a->bc7_delta_frames++;
    a->bc7_bytes += len;
    snprintf(a->active_transport, sizeof(a->active_transport), "%s", "bc7-delta");
    schedule_bc7_present(a, frame.width, frame.height);
    metric_record(&a->bc7_apply_ns, now_ns() - apply_started);
}

static void record_bc7_supercompression(
    struct app *a,
    const struct tb_bc7_supercompression_result *result) {
    a->bc7_compressed_packets++;
    a->bc7_raw_block_bytes += result->raw_block_bytes;
    a->bc7_compressed_block_bytes += result->compressed_block_bytes;
    metric_record(&a->bc7_decompression_ns, result->decompression_ns);
    metric_record(&a->bc7_inverse_transform_ns, result->inverse_transform_ns);
}

static void handle_bc7_compressed_frame(
    struct app *a, const uint8_t *p, size_t len) {
    struct tb_bc7_supercompression_result result;
    if (tb_bc7_supercompression_decode_frame(p, len, &result) != 0) {
        a->bc7_invalid_frames++;
        a->bc7_decompression_failures++;
        request_bc7_keyframe(a, "keyframe-supercompression");
        return;
    }
    record_bc7_supercompression(a, &result);
    handle_bc7_frame(a, result.payload, result.payload_len);
    tb_bc7_supercompression_result_free(&result);
}

static void handle_bc7_compressed_delta(
    struct app *a, const uint8_t *p, size_t len) {
    struct tb_bc7_supercompression_result result;
    if (tb_bc7_supercompression_decode_delta(p, len, &result) != 0) {
        a->bc7_invalid_frames++;
        a->bc7_decompression_failures++;
        request_bc7_keyframe(a, "delta-supercompression");
        return;
    }
    record_bc7_supercompression(a, &result);
    handle_bc7_delta(a, result.payload, result.payload_len);
    tb_bc7_supercompression_result_free(&result);
}

static void ring_read(struct app *a, Uint8 *dst, int len) {
    int first = AUDIO_BUF_CAP - a->audio_buf_tail;
    if (first >= len) {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, len);
    } else {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, first);
        memcpy(dst + first, a->audio_buf, len - first);
    }
    a->audio_buf_tail = (a->audio_buf_tail + len) % AUDIO_BUF_CAP;
    a->audio_buf_size -= len;
}

static void audio_callback(void *userdata, Uint8 *stream, int len) {
    struct app *a = (struct app *)userdata;
    if (a->audio_buf_size >= len) {
        ring_read(a, stream, len);
    } else {
        int available = a->audio_buf_size;
        if (available > 0) ring_read(a, stream, available);
        memset(stream + available, 0, len - available);
    }
}

/* Drive the receiver's master output volume knob (with the system volume HUD).
 * level is clamped to 0.0..1.0. Sets the default output device's scalar volume,
 * preferring the master element and falling back to per-channel when a device
 * has no master volume control. Safe to call from the network/parser thread. */
static void tb_set_system_volume(double level) {
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    Float32 vol = (Float32)level;

    AudioObjectPropertyAddress dev_addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &dev_addr, 0, NULL,
                                   &size, &device) != noErr ||
        device == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress vol_addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain   /* element 0 = master */
    };
    Boolean settable = false;
    if (AudioObjectHasProperty(device, &vol_addr) &&
        AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
        settable) {
        AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        return;
    }

    /* No master element — set the left/right channels individually. */
    for (UInt32 ch = 1; ch <= 2; ch++) {
        vol_addr.mElement = ch;
        settable = false;
        if (AudioObjectHasProperty(device, &vol_addr) &&
            AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
            settable) {
            AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        }
    }
}

/* ---- Callbacks: parser → decoder ------------------------------------- */

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct app *a = (struct app *)ud;
    a->packets_received++;
    a->last_packet_type = type;
    a->last_packet_ms = now_ms();
    switch (type) {
    case TB_PKT_UI_LANGUAGE:
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
                if (a->client_fd < 0 || !a->have_video_frame) {
                    tb_refresh_idle_localized_strings(a);
                }
            }
        }
        break;
    case TB_PKT_HELLO_RECEIVER:
        extract_json_string_field(payload, len, "\"senderName\"", a->sender_text, sizeof(a->sender_text));
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
            }
        }
        if (a->sender_text[0] == '\0') {
            tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.sender_connected");
        }
        {
            char preset[64];
            char source[64];
            char codec[64];
            int capture_w = 0;
            int capture_h = 0;
            preset[0] = '\0';
            source[0] = '\0';
            codec[0] = '\0';
            extract_json_string_field(payload, len, "\"capturePreset\"", preset, sizeof(preset));
            extract_json_string_field(payload, len, "\"captureSource\"", source, sizeof(source));
            extract_json_string_field(payload, len, "\"codec\"", codec, sizeof(codec));
            (void)extract_json_int_field(payload, len, "\"captureWidth\"", &capture_w);
            (void)extract_json_int_field(payload, len, "\"captureHeight\"", &capture_h);

            tb_set_receiver_mode_requested(a->mode_text, sizeof(a->mode_text), capture_w, capture_h, source, preset, codec);
        }
        a->session_active = 1;
        fprintf(stderr, "[main] hello from sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.sender_connected_profile_sent");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        a->session_active = 1;
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_accepted_waiting_frames");
        break;
    case TB_PKT_PARAM_SETS:
        a->session_active = 1;
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        tb_dec_set_param_sets(a->dec, payload, len);
        break;
    case TB_PKT_FRAME:
        a->session_active = 1;
        snprintf(a->active_transport, sizeof(a->active_transport), "%s", "encoded");
        tb_dec_feed_frame(a->dec, payload, len);
        break;
    case TB_PKT_RAW_FRAME:
        a->session_active = 1;
        snprintf(a->active_transport, sizeof(a->active_transport), "%s", "rawNV12");
        handle_raw_frame(a, payload, len);
        break;
    case TB_PKT_BC7_FRAME:
        a->session_active = 1;
        handle_bc7_frame(a, payload, len);
        break;
    case TB_PKT_BC7_TILE_DELTA:
        a->session_active = 1;
        handle_bc7_delta(a, payload, len);
        break;
    case TB_PKT_BC7_COMPRESSED_FRAME:
        a->session_active = 1;
        handle_bc7_compressed_frame(a, payload, len);
        break;
    case TB_PKT_BC7_COMPRESSED_DELTA:
        a->session_active = 1;
        handle_bc7_compressed_delta(a, payload, len);
        break;
    case TB_PKT_BC7_ACK_REQUEST:
        if (len == 4) {
            a->bc7_render_generation =
                ((uint32_t)payload[0] << 24) |
                ((uint32_t)payload[1] << 16) |
                ((uint32_t)payload[2] << 8) |
                (uint32_t)payload[3];
            a->bc7_render_ack_sent = 0;
            a->bc7_ack_requests++;
            if (a->debug_enabled) {
                fprintf(stderr, "[diag] event=bc7-ack-request generation=%u\n",
                        a->bc7_render_generation);
            }
        }
        break;
    case TB_PKT_CURSOR:
        {
            int x = 0;
            int y = 0;
            int w = 0;
            int h = 0;
            int visible = 0;
            int type = 0;
            (void)extract_json_int_field(payload, len, "\"x\"", &x);
            (void)extract_json_int_field(payload, len, "\"y\"", &y);
            (void)extract_json_int_field(payload, len, "\"width\"", &w);
            (void)extract_json_int_field(payload, len, "\"height\"", &h);
            (void)extract_json_bool_field(payload, len, "\"visible\"", &visible);
            (void)extract_json_int_field(payload, len, "\"type\"", &type);
            tb_disp_set_cursor(a->disp, x, y, w, h, visible, type);
        }
        break;
    case TB_PKT_BRIGHTNESS:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_disp_set_brightness(a->disp, level);
        }
        break;
    case TB_PKT_CLIPBOARD:
        {
            char text[4096];
            extract_json_string_field(payload, len, "\"text\"", text, sizeof(text));
            tb_receiver_set_clipboard_text(text);
        }
        break;
    case TB_PKT_VOLUME:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_set_system_volume(level);
        }
        break;
    case TB_PKT_AUDIO_FRAME:
        if (a->audio_device != 0) {
            int queued_audio = 0;
            SDL_LockAudioDevice(a->audio_device);

            // Limit audio backlog to 150ms (150 * 192 = 28800 bytes) to cushion
            // against network / scheduling jitter while still keeping playout tight.
            const int cap_bytes = 28800;
            if (a->audio_buf_size + len > cap_bytes) {
                int excess = (a->audio_buf_size + len) - cap_bytes;
                a->audio_buf_tail = (a->audio_buf_tail + excess) % AUDIO_BUF_CAP;
                a->audio_buf_size -= excess;
            }

            // Write payload to circular buffer
            if (a->audio_buf_size + (int)len <= AUDIO_BUF_CAP) {
                int first = AUDIO_BUF_CAP - a->audio_buf_head;
                if (first >= (int)len) {
                    memcpy(a->audio_buf + a->audio_buf_head, payload, len);
                } else {
                    memcpy(a->audio_buf + a->audio_buf_head, payload, first);
                    memcpy(a->audio_buf, payload + first, len - first);
                }
                a->audio_buf_head = (a->audio_buf_head + (int)len) % AUDIO_BUF_CAP;
                a->audio_buf_size += (int)len;
                queued_audio = 1;
            }

            SDL_UnlockAudioDevice(a->audio_device);
            if (tb_receiver_audio_should_start(
                    a->audio_playing,
                    queued_audio ? len : 0)) {
                SDL_PauseAudioDevice(a->audio_device, 0);
                a->audio_playing = 1;
            }
        }
        break;
    case TB_PKT_INPUT_EVENT:
        tb_receiver_apply_input_event(payload, len);
        break;
    case TB_PKT_INPUT_CONTROL:
        tb_receiver_apply_input_control_mode(a, payload, len);
        break;
    case TB_PKT_HEARTBEAT:
        {
            struct tb_heartbeat_request request;
            if (tb_heartbeat_parse_request(
                    payload,
                    len,
                    &request) != 0) {
                tb_receiver_diagnostics_log(
                    &a->diagnostics,
                    a->last_packet_ms,
                    "heartbeat_malformed",
                    NULL);
                break;
            }
            a->last_heartbeat_sequence = request.sequence;
            a->last_heartbeat_sequence_valid = 1;

            const uint64_t receiver_timestamp_ms = now_ms();
            uint8_t packet[1024];
            const int packet_length = tb_heartbeat_build_ack_packet(
                packet,
                sizeof(packet),
                &request,
                receiver_timestamp_ms,
                a->diagnostics.process_instance_id,
                a->max_loop_lag_ms,
                a->bc7_applied_sequence);
            if (packet_length <= 0) {
                a->heartbeat_ack_send_error = EMSGSIZE;
                break;
            }
            if (send_all(
                    a->client_fd,
                    packet,
                    (size_t)packet_length) != 0) {
                a->heartbeat_ack_send_error =
                    errno != 0 ? errno : EIO;
                char fields[192];
                snprintf(
                    fields,
                    sizeof(fields),
                    "\"sequence\":%llu,\"errno\":%d",
                    (unsigned long long)request.sequence,
                    a->heartbeat_ack_send_error);
                tb_receiver_diagnostics_log(
                    &a->diagnostics,
                    receiver_timestamp_ms,
                    "heartbeat_ack_error",
                    fields);
                break;
            }
            char fields[320];
            snprintf(
                fields,
                sizeof(fields),
                "\"sequence\":%llu,\"eventLoopLagMs\":%llu,"
                "\"appliedSequence\":%llu",
                (unsigned long long)request.sequence,
                (unsigned long long)a->max_loop_lag_ms,
                (unsigned long long)a->bc7_applied_sequence);
            tb_receiver_diagnostics_log(
                &a->diagnostics,
                receiver_timestamp_ms,
                "heartbeat_ack_sent",
                fields);
            a->max_loop_lag_ms = 0;
        }
        break;
    case TB_PKT_TEST_DATA:
        /* Performance test data; discard */
        break;
    case TB_PKT_TEARDOWN:
        fprintf(stderr, "[main] teardown requested by sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_closed_by_sender");
        a->close_requested = 1;
        break;
    default:
        fprintf(stderr, "[main] unknown pkt type=0x%02x\n", type);
        break;
    }
}

/* ---- Networking helpers ---------------------------------------------- */

enum tb_drain_result {
    TB_DRAIN_PEER_FIN = -3,
    TB_DRAIN_READ_ERROR = -2,
    TB_DRAIN_PARSER_ERROR = -1,
    TB_DRAIN_NO_DATA = 0,
    TB_DRAIN_DATA = 1
};

static int drain_socket(struct app *a, int *error_code) {
    uint8_t buf[1024 * 1024];
    int saw_data = 0;
    size_t drained_bytes = 0;
    if (error_code) *error_code = 0;
    for (;;) {
        ssize_t n = read(a->client_fd, buf, sizeof(buf));
        if (n > 0) {
            saw_data = 1;
            drained_bytes += (size_t)n;
            a->received_bytes += (uint64_t)n;
            if (tb_parser_feed(&a->parser, buf, (size_t)n) < 0) {
                return TB_DRAIN_PARSER_ERROR;
            }
            if (drained_bytes >= 32u * 1024u * 1024u) {
                return TB_DRAIN_DATA;
            }
        } else if (n == 0) {
            return TB_DRAIN_PEER_FIN;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return saw_data ? TB_DRAIN_DATA : TB_DRAIN_NO_DATA;
            }
            if (error_code) *error_code = errno;
            perror("[main] read");
            return TB_DRAIN_READ_ERROR;
        }
    }
}

static void write_be32(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)((value >> 24) & 0xff);
    dst[1] = (uint8_t)((value >> 16) & 0xff);
    dst[2] = (uint8_t)((value >> 8) & 0xff);
    dst[3] = (uint8_t)(value & 0xff);
}

static int send_all(int fd, const uint8_t *buf, size_t len) {
    /* Bound the EAGAIN retry loop: this runs on the event-loop thread, so an
     * unresponsive reader (half-open peer, saturated link) must not wedge
     * rendering and quit handling forever. 2s of zero progress means the
     * session is effectively dead; give up and let the caller/watchdog
     * tear it down. */
    const uint64_t deadline_ms = now_ms() + 2000;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (now_ms() >= deadline_ms) {
                fprintf(stderr, "[net] send stalled for 2s; dropping write\n");
                return -1;
            }
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
}

static void tb_receiver_send_input_event(struct app *a,
                                         const char *kind,
                                         int has_dx, int dx,
                                         int has_dy, int dy,
                                         int has_scroll_x, int scroll_x,
                                         int has_scroll_y, int scroll_y,
                                         int has_key_code, uint16_t key_code) {
    if (!a || a->client_fd < 0) return;
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return;

    char json[256];
    int len = snprintf(json, sizeof(json), "{\"kind\":\"%s\"", kind ? kind : "");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    if (has_dx) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dx\":%d", dx);
    if (has_dy) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dy\":%d", dy);
    if (has_scroll_x) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollX\":%d", scroll_x);
    if (has_scroll_y) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollY\":%d", scroll_y);
    if (has_key_code) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"keyCode\":%u", (unsigned int)key_code);
    len += snprintf(json + len, sizeof(json) - (size_t)len, "}");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_INPUT_EVENT;
    memcpy(pkt + 5, json, (size_t)len);
    a->input_events_sent += 1;
    if (tb_should_log_input_event(a->input_events_sent)) {
        tb_receiver_input_log("[input][receiver->sender] send #%llu kind=%s dx=%d dy=%d sx=%d sy=%d key=%u mode=%s",
                              (unsigned long long)a->input_events_sent,
                              kind ? kind : "?",
                              has_dx ? dx : 0,
                              has_dy ? dy : 0,
                              has_scroll_x ? scroll_x : 0,
                              has_scroll_y ? scroll_y : 0,
                              has_key_code ? (unsigned int)key_code : 0,
                              a->input_control_mode);
    }
    (void)send_all(a->client_fd, pkt, 5 + (size_t)len);
}

static void tb_receiver_send_target_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevTarget" : "switchNextTarget",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_sync_modifier_state(struct app *a,
                                            int command_down,
                                            int shift_down,
                                            int option_down,
                                            int control_down,
                                            int caps_down) {
    if (!a) return;

    struct {
        int *state;
        int desired;
        uint16_t key_code;
    } modifiers[] = {
        { &a->sent_command_down, command_down, 55 },
        { &a->sent_shift_down,   shift_down,   56 },
        { &a->sent_option_down,  option_down,  58 },
        { &a->sent_control_down, control_down, 59 },
        { &a->sent_caps_down,    caps_down,    57 }
    };

    for (size_t i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++) {
        if (*modifiers[i].state == modifiers[i].desired) continue;
        tb_receiver_send_input_event(a,
                                     modifiers[i].desired ? "keyDown" : "keyUp",
                                     0, 0, 0, 0, 0, 0, 0, 0, 1, modifiers[i].key_code);
        *modifiers[i].state = modifiers[i].desired;
    }
}

static void tb_receiver_send_space_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevSpace" : "switchNextSpace",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_space_switch_callback(int direction, void *context) {
    struct app *a = (struct app *)context;
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;
    tb_receiver_send_space_switch(a, direction);
}

static void tb_receiver_send_deactivate_control(struct app *a) {
    tb_receiver_send_input_event(a,
                                 "deactivateInputControl",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static CGEventRef tb_receiver_input_tap_callback(CGEventTapProxy proxy,
                                                 CGEventType type,
                                                 CGEventRef event,
                                                 void *user_info) {
    (void)proxy;
    struct app *a = (struct app *)user_info;
    if (!a) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (a->input_tap) CGEventTapEnable(a->input_tap, true);
        return event;
    }

    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return event;

    /* Only drive the sender while the user is actually on the shared display
     * window's Space. The global tap also sees events from other receiver
     * Spaces; forwarding those would make the sender's cursor jump while the
     * user is doing local work on the receiver. When the window is on a
     * different Space, pass the event through untouched and forward nothing. */
    if (!tb_disp_window_on_active_space(a->disp)) return event;

    int should_consume = 0;

    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        int dx = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int dy = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        CGPoint location = CGEventGetLocation(event);
        CGRect bounds = CGDisplayBounds(CGMainDisplayID());
        uint64_t now = now_ms();
        if (now - a->last_target_switch_ms > 450) {
            if (location.x <= CGRectGetMinX(bounds) + 2.0 && dx < 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (location.x >= CGRectGetMaxX(bounds) - 2.0 && dx > 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        const char *kind = "move";
        if (type == kCGEventLeftMouseDragged) kind = "leftDrag";
        else if (type == kCGEventRightMouseDragged) kind = "rightDrag";
        else if (type == kCGEventOtherMouseDragged) kind = "otherDrag";
        tb_receiver_send_input_event(a, kind, 1, dx, 1, dy, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventLeftMouseDown:
        tb_receiver_send_input_event(a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventLeftMouseUp:
        tb_receiver_send_input_event(a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseDown:
        tb_receiver_send_input_event(a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseUp:
        tb_receiver_send_input_event(a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseDown:
        tb_receiver_send_input_event(a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseUp:
        tb_receiver_send_input_event(a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventScrollWheel: {
        int sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        int sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        int point_sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        int point_sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        int is_continuous = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        uint64_t now = now_ms();
        if ((effective_flags & kCGEventFlagMaskAlternate) &&
            (llabs((long long)point_sx) > llabs((long long)point_sy) * 2 || llabs((long long)sx) > llabs((long long)sy) * 2) &&
            now - a->last_space_switch_ms > 300) {
            int direction = 0;
            if (point_sx != 0) direction = point_sx > 0 ? 1 : -1;
            else if (sx != 0) direction = sx > 0 ? 1 : -1;
            if (direction != 0) {
                a->last_space_switch_ms = now;
                a->space_gesture_accum_x = 0;
                tb_receiver_send_space_switch(a, direction);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        if (is_continuous &&
            (point_sx != 0 || point_sy != 0) &&
            llabs((long long)point_sx) > llabs((long long)point_sy) * 2) {
            if (now - a->last_space_gesture_ms > 250) {
                a->space_gesture_accum_x = 0;
            }
            a->last_space_gesture_ms = now;
            a->space_gesture_accum_x += point_sx;
            if (llabs((long long)a->space_gesture_accum_x) >= 45 &&
                now - a->last_space_switch_ms > 450) {
                a->last_space_switch_ms = now;
                tb_receiver_send_space_switch(a, a->space_gesture_accum_x > 0 ? 1 : -1);
                a->space_gesture_accum_x = 0;
            }
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if (now - a->last_space_gesture_ms > 250) {
            a->space_gesture_accum_x = 0;
        }
        tb_receiver_send_input_event(a, "scroll", 0, 0, 0, 0, 1, sx, 1, sy, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyDown: {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            tb_receiver_send_deactivate_control(a);
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand)) {
            if (key_code == 123) {
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (key_code == 124) {
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        tb_receiver_send_input_event(a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyUp:
    {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand) &&
            (key_code == 123 || key_code == 124)) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        tb_receiver_send_input_event(a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventFlagsChanged: {
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        should_consume = a->input_tap_consumes_events;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        break;
    }
    default:
        break;
    }

    return should_consume ? NULL : event;
}

static void tb_receiver_stop_input_tap(struct app *a) {
    if (!a) return;
    if (a->input_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
        CFRelease(a->input_tap_source);
        a->input_tap_source = NULL;
    }
    if (a->input_tap) {
        CFMachPortInvalidate(a->input_tap);
        CFRelease(a->input_tap);
        a->input_tap = NULL;
    }
    a->input_tap_consumes_events = 0;
}

static void tb_receiver_start_input_tap(struct app *a) {
    if (!a || a->input_tap) return;

    if (!tb_receiver_input_monitoring_trusted()) {
        return;
    }

    const int can_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
    CGEventTapOptions tap_options = can_consume ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly;

    CGEventMask mask =
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged);

    a->input_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        tap_options,
        mask,
        tb_receiver_input_tap_callback,
        a
    );
    if (!a->input_tap) {
        tb_receiver_input_log("[input] global event tap unavailable; will fall back to SDL window input");
        return;
    }

    a->input_tap_source = CFMachPortCreateRunLoopSource(NULL, a->input_tap, 0);
    if (!a->input_tap_source) {
        tb_receiver_stop_input_tap(a);
        tb_receiver_input_log("[input] failed to create runloop source for event tap; using SDL fallback");
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(a->input_tap, true);
    a->input_tap_consumes_events = can_consume;
    tb_receiver_input_log("[input] global event tap enabled for receiverMaster mode (consume=%s)",
                          can_consume ? "true" : "false");
}

static void tb_receiver_refresh_input_capture(struct app *a) {
    if (!a) return;
    if (strcmp(a->input_control_mode, "receiverMaster") == 0 && a->client_fd >= 0) {
        const int wants_global_tap = tb_receiver_input_monitoring_trusted() ? 1 : 0;
        const int wants_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
        if (a->input_tap && (!wants_global_tap || a->input_tap_consumes_events != wants_consume)) {
            tb_receiver_stop_input_tap(a);
        }
        tb_receiver_start_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 1);
        tb_disp_set_input_capture_active(a->disp, a->input_tap == NULL ? 1 : 0);
        tb_gesture_bridge_set_active(1);
        tb_receiver_input_log("[input] receiverMaster capture path = %s",
                              a->input_tap ? "global-tap" : "sdl-fallback");
    } else {
        tb_receiver_stop_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 0);
        tb_disp_set_input_capture_active(a->disp, 0);
        tb_gesture_bridge_set_active(0);
        tb_receiver_input_log("[input] input capture disabled");
    }
}

static void send_receiver_info(struct app *a) {
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

    /* Always advertise the intended iMac target panel, not the transient
     * SDL window/debug drawable size. Using the drawable here breaks the
     * sender's virtual display creation path when running windowed or on
     * scaled desktops because macOS rejects a HiDPI mode larger than the
     * advertised backing panel. */
    const uint32_t panel_w = 5120;
    const uint32_t panel_h = 2880;
    const uint32_t mode_w = 2560;
    const uint32_t mode_h = 1440;
    const uint32_t capture_w = 2560;
    const uint32_t capture_h = 1440;

    char escaped_name[256];
    size_t out = 0;
    for (size_t i = 0; info.name[i] != '\0' && out + 2 < sizeof(escaped_name); i++) {
        unsigned char c = (unsigned char)info.name[i];
        if (c == '"' || c == '\\') {
            escaped_name[out++] = '\\';
            escaped_name[out++] = (char)c;
        } else if (c >= 0x20) {
            escaped_name[out++] = (char)c;
        }
    }
    escaped_name[out] = '\0';

    char json[1024];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"receiverName\":\"%s\",\"panelWidth\":%u,\"panelHeight\":%u,"
        "\"modeWidth\":%u,\"modeHeight\":%u,\"refreshRate\":60,"
        "\"hiDPI\":true,\"captureWidth\":%u,\"captureHeight\":%u,"
        "\"receiverVersion\":\"%s\",\"receiverBuild\":\"%s\",\"receiverCommit\":\"%s\","
        "\"supportsHEVCDecode\":%s,\"supportsRawNV12\":true,"
        "\"supportsRawNV12LZ4\":true,\"supportsRawNV12TileRuns\":true,"
        "\"supportsHeartbeatAck\":true,"
        "\"supportsBC7Mode6\":%s,"
        "\"supportsBC7TileDelta\":%s,\"supportsBC7LZFSE\":%s,"
        "\"supportsBC7LZ4\":%s,"
        "\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s}",
        escaped_name,
        panel_w,
        panel_h,
        mode_w,
        mode_h,
        capture_w,
        capture_h,
        TB_RECEIVER_VERSION,
        TB_RECEIVER_BUILD,
        TB_RECEIVER_COMMIT,
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        tb_disp_supports_bc7(a->disp) ? "true" : "false",
        tb_disp_supports_bc7(a->disp) ? "true" : "false",
        tb_disp_supports_bc7(a->disp) ? "true" : "false",
        tb_disp_supports_bc7(a->disp) ? "true" : "false",
        tb_receiver_input_monitoring_trusted() ? "true" : "false",
        tb_receiver_accessibility_trusted() ? "true" : "false"
    );
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) return;

    const size_t packet_len = 4 + 1 + (size_t)json_len;
    uint8_t *pkt = (uint8_t *)calloc(1, packet_len);
    if (!pkt) return;

    write_be32(pkt, (uint32_t)(1 + json_len));
    pkt[4] = TB_PKT_DISPLAY_PROFILE;
    memcpy(pkt + 5, json, (size_t)json_len);

    if (send_all(a->client_fd, pkt, packet_len) == 0) {
        fprintf(stderr,
                "[main] sent display profile: panel=%ux%u mode=%ux%u hidpi "
                "name=%s version=%s build=%s commit=%s\n",
                panel_w, panel_h, mode_w, mode_h, info.name,
                TB_RECEIVER_VERSION, TB_RECEIVER_BUILD, TB_RECEIVER_COMMIT);
    }
    free(pkt);
}

static int send_receiver_metrics(
    struct app *a, double fps, double present_fps, double gbps) {
    if (!a || a->client_fd < 0) return 0;
    const struct tb_metric_summary packet_interval =
        metric_summary(&a->bc7_packet_interval_ns);
    const struct tb_metric_summary apply = metric_summary(&a->bc7_apply_ns);
    const struct tb_metric_summary upload = metric_summary(&a->bc7_upload_ns);
    const struct tb_metric_summary present = metric_summary(&a->bc7_present_ns);
    const struct tb_metric_summary present_interval =
        metric_summary(&a->bc7_present_interval_ns);
    const struct tb_metric_summary decompression =
        metric_summary(&a->bc7_decompression_ns);
    const struct tb_metric_summary inverse_transform =
        metric_summary(&a->bc7_inverse_transform_ns);
    const struct tb_metric_summary raw_shadow =
        metric_summary(&a->raw_shadow_commit_ns);
    const struct tb_metric_summary raw_upload =
        metric_summary(&a->raw_upload_ns);
    const struct tb_metric_summary raw_checksum =
        metric_summary(&a->raw_checksum_ns);
    char json[3072];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"fps\":%.3f,\"presentFPS\":%.3f,\"networkGbps\":%.6f,\"packets\":%llu,"
        "\"bc7Frames\":%llu,\"bc7PayloadBytes\":%llu,\"bc7Invalid\":%llu,"
        "\"renderFailures\":%llu,\"bc7Deltas\":%llu,\"appliedSequence\":%llu,"
        "\"keyframeRequests\":%llu,\"packetIntervalP50Ms\":%.3f,"
        "\"packetIntervalP95Ms\":%.3f,\"packetIntervalP99Ms\":%.3f,"
        "\"applyP50Ms\":%.3f,\"applyP95Ms\":%.3f,\"applyP99Ms\":%.3f,"
        "\"uploadP50Ms\":%.3f,\"uploadP95Ms\":%.3f,\"uploadP99Ms\":%.3f,"
        "\"presentP50Ms\":%.3f,\"presentP95Ms\":%.3f,\"presentP99Ms\":%.3f,"
        "\"presentIntervalP50Ms\":%.3f,\"presentIntervalP95Ms\":%.3f,"
        "\"presentIntervalP99Ms\":%.3f,\"presentedFrames\":%llu,"
        "\"coalescedFrames\":%llu,\"compressedPackets\":%llu,"
        "\"decompressionFailures\":%llu,\"rawBlockBytes\":%llu,"
        "\"compressedBlockBytes\":%llu,\"decompressionP50Ms\":%.3f,"
        "\"decompressionP95Ms\":%.3f,\"decompressionP99Ms\":%.3f,"
        "\"inverseTransformP50Ms\":%.3f,\"inverseTransformP95Ms\":%.3f,"
        "\"inverseTransformP99Ms\":%.3f,\"rawFullFrames\":%llu,"
        "\"rawRegionFrames\":%llu,\"rawTileRunFrames\":%llu,"
        "\"rawTileRuns\":%llu,\"rawShadowCommitP50Ms\":%.3f,"
        "\"rawShadowCommitP95Ms\":%.3f,\"rawShadowCommitP99Ms\":%.3f,"
        "\"rawUploadP50Ms\":%.3f,\"rawUploadP95Ms\":%.3f,"
        "\"rawUploadP99Ms\":%.3f,\"rawChecksumP50Ms\":%.3f,"
        "\"rawChecksumP95Ms\":%.3f,\"rawChecksumP99Ms\":%.3f}",
        fps,
        present_fps,
        gbps,
        (unsigned long long)a->packets_received,
        (unsigned long long)a->bc7_frames,
        (unsigned long long)a->bc7_bytes,
        (unsigned long long)a->bc7_invalid_frames,
        (unsigned long long)a->bc7_render_failures,
        (unsigned long long)a->bc7_delta_frames,
        (unsigned long long)a->bc7_applied_sequence,
        (unsigned long long)a->bc7_keyframe_requests,
        ns_to_ms(packet_interval.p50),
        ns_to_ms(packet_interval.p95),
        ns_to_ms(packet_interval.p99),
        ns_to_ms(apply.p50),
        ns_to_ms(apply.p95),
        ns_to_ms(apply.p99),
        ns_to_ms(upload.p50),
        ns_to_ms(upload.p95),
        ns_to_ms(upload.p99),
        ns_to_ms(present.p50),
        ns_to_ms(present.p95),
        ns_to_ms(present.p99),
        ns_to_ms(present_interval.p50),
        ns_to_ms(present_interval.p95),
        ns_to_ms(present_interval.p99),
        (unsigned long long)a->bc7_presented_frames,
        (unsigned long long)a->bc7_coalesced_frames,
        (unsigned long long)a->bc7_compressed_packets,
        (unsigned long long)a->bc7_decompression_failures,
        (unsigned long long)a->bc7_raw_block_bytes,
        (unsigned long long)a->bc7_compressed_block_bytes,
        ns_to_ms(decompression.p50),
        ns_to_ms(decompression.p95),
        ns_to_ms(decompression.p99),
        ns_to_ms(inverse_transform.p50),
        ns_to_ms(inverse_transform.p95),
        ns_to_ms(inverse_transform.p99),
        (unsigned long long)a->raw_full_frames,
        (unsigned long long)a->raw_region_frames,
        (unsigned long long)a->raw_tile_run_frames,
        (unsigned long long)a->raw_tile_runs,
        ns_to_ms(raw_shadow.p50),
        ns_to_ms(raw_shadow.p95),
        ns_to_ms(raw_shadow.p99),
        ns_to_ms(raw_upload.p50),
        ns_to_ms(raw_upload.p95),
        ns_to_ms(raw_upload.p99),
        ns_to_ms(raw_checksum.p50),
        ns_to_ms(raw_checksum.p95),
        ns_to_ms(raw_checksum.p99)
    );
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) {
        errno = EMSGSIZE;
        return -1;
    }

    const size_t packet_len = 5u + (size_t)json_len;
    uint8_t packet[5 + 3072];
    write_be32(packet, (uint32_t)(1 + json_len));
    packet[4] = TB_PKT_RECEIVER_METRICS;
    memcpy(packet + 5, json, (size_t)json_len);
    return send_all(a->client_fd, packet, packet_len);
}

static int tcp_state_for_fd(int fd) {
    if (fd < 0) return -1;
    struct tcp_connection_info info;
    socklen_t info_length = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (getsockopt(
            fd,
            IPPROTO_TCP,
            TCP_CONNECTION_INFO,
            &info,
            &info_length) != 0) {
        return -1;
    }
    return info.tcpi_state;
}

static void close_client(
    struct app *a,
    enum tb_receiver_close_reason reason,
    int error_code,
    uint64_t close_time_ms,
    uint64_t idle_ms) {
    int socket_error = 0;
    socklen_t socket_error_length = sizeof(socket_error);
    const int tcp_state = tcp_state_for_fd(a->client_fd);
    if (a->client_fd >= 0 &&
        getsockopt(
            a->client_fd,
            SOL_SOCKET,
            SO_ERROR,
            &socket_error,
            &socket_error_length) != 0) {
        socket_error = -1;
    }
    const uint64_t last_packet_age_ms =
        close_time_ms >= a->last_packet_ms
            ? close_time_ms - a->last_packet_ms
            : 0;
    char heartbeat_sequence[32];
    snprintf(
        heartbeat_sequence,
        sizeof(heartbeat_sequence),
        "%s",
        a->last_heartbeat_sequence_valid ? "" : "null");
    if (a->last_heartbeat_sequence_valid) {
        snprintf(
            heartbeat_sequence,
            sizeof(heartbeat_sequence),
            "%llu",
            (unsigned long long)a->last_heartbeat_sequence);
    }
    char fields[2048];
    snprintf(
        fields,
        sizeof(fields),
        "\"reason\":\"%s\",\"errno\":%d,\"socketError\":%d,"
        "\"tcpState\":%d,\"nowMs\":%llu,\"lastReceiveMs\":%llu,"
        "\"idleMs\":%llu,\"lastPacketType\":%u,\"lastPacketMs\":%llu,"
        "\"lastPacketAgeMs\":%llu,\"lastHeartbeatSequence\":%s,"
        "\"transport\":\"%s\",\"sessionActive\":%s,"
        "\"frames\":%llu,\"packets\":%llu,\"bytes\":%llu,"
        "\"invalidFrames\":%llu,\"renderFailures\":%llu,"
        "\"appliedSequence\":%llu,\"keyframeRequests\":%llu",
        tb_receiver_close_reason_name(reason),
        error_code,
        socket_error,
        tcp_state,
        (unsigned long long)close_time_ms,
        (unsigned long long)a->last_recv_ms,
        (unsigned long long)idle_ms,
        (unsigned int)a->last_packet_type,
        (unsigned long long)a->last_packet_ms,
        (unsigned long long)last_packet_age_ms,
        heartbeat_sequence,
        a->active_transport,
        a->session_active ? "true" : "false",
        (unsigned long long)a->frames,
        (unsigned long long)a->packets_received,
        (unsigned long long)a->received_bytes,
        (unsigned long long)a->bc7_invalid_frames,
        (unsigned long long)a->bc7_render_failures,
        (unsigned long long)a->bc7_applied_sequence,
        (unsigned long long)a->bc7_keyframe_requests);
    tb_receiver_diagnostics_log(
        &a->diagnostics,
        close_time_ms,
        "session_close",
        fields);
    tb_receiver_diagnostics_flush(&a->diagnostics, 1);
    if (a->debug_enabled && a->client_fd >= 0) {
        fprintf(stderr,
                "[diag] event=disconnect reason=%s errno=%d tcpState=%d "
                "idleMs=%llu transport=%s frames=%llu packets=%llu "
                "bytes=%llu bc7Frames=%llu bc7Invalid=%llu renderFailures=%llu "
                "bc7Deltas=%llu appliedSequence=%llu keyframeRequests=%llu "
                "ackRequests=%llu acksSent=%llu\n",
                tb_receiver_close_reason_name(reason),
                error_code,
                tcp_state,
                (unsigned long long)idle_ms,
                a->active_transport,
                (unsigned long long)a->frames,
                (unsigned long long)a->packets_received,
                (unsigned long long)a->received_bytes,
                (unsigned long long)a->bc7_frames,
                (unsigned long long)a->bc7_invalid_frames,
                (unsigned long long)a->bc7_render_failures,
                (unsigned long long)a->bc7_delta_frames,
                (unsigned long long)a->bc7_applied_sequence,
                (unsigned long long)a->bc7_keyframe_requests,
                (unsigned long long)a->bc7_ack_requests,
                (unsigned long long)a->bc7_acks_sent);
    }
    if (a->client_fd >= 0) close(a->client_fd);
    a->client_fd = -1;
    a->session_active = 0;
    a->close_requested = 0;
    a->heartbeat_ack_send_error = 0;
    a->have_video_frame = 0;
    a->bc7_render_ack_sent = 0;
    a->bc7_render_generation = 0;
    a->bc7_last_keyframe_request_ms = 0;
    a->bc7_keyframe_request_pending = 0;
    reset_bc7_delta_state(a);
    reset_raw_state(a);
    snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    SDL_EnableScreenSaver();
    tb_receiver_refresh_input_capture(a);
    tb_disp_set_connection_state(a->disp, 0);
    tb_disp_set_cursor(a->disp, 0, 0, 1, 1, 0, 0);
    tb_refresh_idle_localized_strings(a);
    a->last_clipboard_text[0] = '\0';
    tb_parser_free(&a->parser);
    tb_parser_init(&a->parser, on_packet, a);
    tb_dec_reset(a->dec);   /* fresh decoder for next session */
    if (a->audio_device != 0) {
        if (tb_receiver_audio_should_pause(0, a->audio_playing)) {
            SDL_PauseAudioDevice(a->audio_device, 1);
            a->audio_playing = 0;
        }
        SDL_LockAudioDevice(a->audio_device);
        a->audio_buf_head = 0;
        a->audio_buf_tail = 0;
        a->audio_buf_size = 0;
        SDL_UnlockAudioDevice(a->audio_device);
    }
    fprintf(
        stderr,
        "[main] client disconnected reason=%s errno=%d idle_ms=%llu\n",
        tb_receiver_close_reason_name(reason),
        error_code,
        (unsigned long long)idle_ms);
}

/* Build the display string for the host/IP line of the status screen.
 * have_ip: non-zero if ip_fallback is a real IP, zero if no IP is available.
 * Called once at startup (and when the IP changes) to cache the result in
 * a.display_host — do NOT call gethostname() in the render loop. */
static void build_display_host(char *buf, size_t bufsz, const char *ip_fallback, int have_ip) {
    if (!buf || bufsz == 0) return;
    char host[96] = {0};
    if (gethostname(host, sizeof(host)) == 0 && host[0] != '\0' && strcmp(host, "localhost") != 0) {
        char short_host[96] = {0};
        size_t i = 0;
        for (; host[i] != '\0' && host[i] != '.' && i + 1 < sizeof(short_host); i++) {
            short_host[i] = host[i];
        }
        short_host[i] = '\0';
        if (short_host[0] != '\0') {
            if (have_ip && ip_fallback && ip_fallback[0] != '\0') {
                snprintf(buf, bufsz, "%s (%s)", short_host, ip_fallback);
            } else {
                snprintf(buf, bufsz, "%s", short_host);
            }
            return;
        }
    }
    snprintf(buf, bufsz, "%s", (have_ip && ip_fallback && ip_fallback[0] != '\0')
             ? ip_fallback : tb_i18n_get("receiver.network.not_detected"));
}

/* ---- Main ------------------------------------------------------------ */

int main(int argc, char **argv) {
    int fullscreen = 1;
    int print_capabilities = 0;
    int debug_enabled = 0;
    const uint64_t startup_monotonic_ms = now_ms();
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0) {
            fullscreen = 0;
        } else if (strcmp(argv[i], "--capabilities") == 0) {
            print_capabilities = 1;
        } else if (strcmp(argv[i], "--debug") == 0) {
            debug_enabled = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: %s [--windowed] [--debug] [--capabilities]\n", argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (print_capabilities) {
#if defined(__x86_64__)
        const char *architecture = "x86_64";
#elif defined(__arm64__) || defined(__aarch64__)
        const char *architecture = "arm64";
#else
        const char *architecture = "unknown";
#endif
        char metal_device[256] = {0};
        (void)tb_bc7_renderer_copy_device_name(metal_device, sizeof(metal_device));
        printf(
            "{\"version\":\"%s\",\"build\":\"%s\",\"commit\":\"%s\",\"architecture\":\"%s\","
            "\"metalDevice\":\"%s\",\"supportsBC7Mode6\":%s,"
            "\"supportsBC7TileDelta\":%s,\"supportsBC7LZFSE\":%s,"
            "\"supportsBC7LZ4\":%s,\"supportsRawNV12\":true,"
            "\"supportsRawNV12LZ4\":true,\"supportsRawNV12TileRuns\":true,"
            "\"supportsHeartbeatAck\":true}\n",
            TB_RECEIVER_VERSION,
            TB_RECEIVER_BUILD,
            TB_RECEIVER_COMMIT,
            architecture,
            metal_device,
            tb_bc7_renderer_supported() ? "true" : "false",
            tb_bc7_renderer_supported() ? "true" : "false",
            tb_bc7_renderer_supported() ? "true" : "false",
            tb_bc7_renderer_supported() ? "true" : "false"
        );
        return 0;
    }

    if (debug_enabled) {
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IOLBF, 0);
    }

    char startup_language_pref[8];
    tb_receiver_load_language_preference(startup_language_pref, sizeof(startup_language_pref));
    if (strcmp(startup_language_pref, "auto") != 0) {
        tb_i18n_set_runtime_language(startup_language_pref);
    }
    (void)tb_i18n_init();

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);

    char tb_ip[64] = {0};
    char net_ip[64] = {0};
    if (tb_net_get_tb_ip(tb_ip, sizeof(tb_ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", tb_ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    if (tb_net_get_lan_ip(net_ip, sizeof(net_ip)) == 0) {
        printf("TBReceiver: Local network IP = %s\n", net_ip);
    } else {
        printf("TBReceiver: warning, no LAN IP detected (RFC1918 IPv4)\n");
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    a.server_fd = -1;
    a.client_fd = -1;
    a.debug_enabled = debug_enabled;
    (void)tb_receiver_diagnostics_init(
        &a.diagnostics,
        TB_RECEIVER_VERSION,
        TB_RECEIVER_BUILD,
        TB_RECEIVER_COMMIT,
        startup_monotonic_ms);
    snprintf(a.active_transport, sizeof(a.active_transport), "%s", "none");
    {
        char host[96] = {0};
        if (gethostname(host, sizeof(host)) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "%s", "Receiver");
        }
        snprintf(a.bonjour_name, sizeof(a.bonjour_name), "TargetBridge %s", host);
    }
    snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", tb_ip);
    snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", net_ip);
    snprintf(a.ip_text, sizeof(a.ip_text), "%s", tb_ip[0] ? tb_ip : (net_ip[0] ? net_ip : tb_i18n_get("receiver.network.not_detected")));
    snprintf(a.language_pref, sizeof(a.language_pref), "%s", startup_language_pref);
    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
    a.last_input_monitoring_trusted = -1;
    a.last_accessibility_trusted = -1;
    tb_refresh_idle_localized_strings(&a);
    build_display_host(a.display_host, sizeof(a.display_host), a.ip_text, tb_ip[0] || net_ip[0]);
    tb_receiver_apply_language_preference(&a);
    tb_gesture_bridge_install(tb_receiver_space_switch_callback, &a);
    tb_gesture_bridge_set_active(0);

    a.disp = tb_disp_create(fullscreen);
    if (!a.disp) {
        fprintf(stderr, "tb_disp_create failed\n");
        tb_receiver_diagnostics_log(
            &a.diagnostics,
            now_ms(),
            "startup_failure",
            "\"component\":\"display\"");
        tb_receiver_diagnostics_close(
            &a.diagnostics,
            now_ms(),
            "startup_failure");
        return 1;
    }

    /* Open SDL Audio Device */
    SDL_AudioSpec spec;
    SDL_zero(spec);
    spec.freq = 48000;
    spec.format = AUDIO_S16LSB; // 16-bit signed, little-endian PCM
    spec.channels = 2;          // Stereo
    spec.samples = 1024;        // Buffer size (approx 21.3ms)
    spec.callback = audio_callback;
    spec.userdata = &a;
    SDL_AudioSpec obtained;
    a.audio_device = SDL_OpenAudioDevice(NULL, 0, &spec, &obtained, 0);
    if (a.audio_device != 0) {
        fprintf(stderr, "[main] SDL audio device opened paused: 48000Hz stereo 16-bit PCM (obtained %d samples)\n", obtained.samples);
    } else {
        fprintf(stderr, "[main] warning: SDL_OpenAudioDevice failed: %s\n", SDL_GetError());
    }

    struct tb_display_info boot_info;
    if (tb_disp_get_info(a.disp, &boot_info) == 0) {
        snprintf(a.panel_text, sizeof(a.panel_text), "%u x %u px (%s)",
                 boot_info.active_w, boot_info.active_h, boot_info.name);
    } else {
        tb_copy_i18n(a.panel_text, sizeof(a.panel_text), "receiver.panel.default");
    }
    bonjour_update(&a, TB_PORT);

    a.dec = tb_dec_create(on_frame, &a);
    if (!a.dec) {
        fprintf(stderr, "tb_dec_create failed\n");
        tb_receiver_diagnostics_log(
            &a.diagnostics,
            now_ms(),
            "startup_failure",
            "\"component\":\"decoder\"");
        tb_disp_destroy(a.disp);
        tb_receiver_diagnostics_close(
            &a.diagnostics,
            now_ms(),
            "startup_failure");
        return 1;
    }

    tb_parser_init(&a.parser, on_packet, &a);

    a.server_fd = tb_net_listen(TB_PORT);
    if (a.server_fd < 0) {
        fprintf(stderr, "tb_net_listen failed\n");
        tb_receiver_diagnostics_log(
            &a.diagnostics,
            now_ms(),
            "startup_failure",
            "\"component\":\"listen_socket\"");
        tb_parser_free(&a.parser);
        tb_dec_destroy(a.dec);
        tb_disp_destroy(a.disp);
        tb_receiver_diagnostics_close(
            &a.diagnostics,
            now_ms(),
            "startup_failure");
        return 1;
    }

    a.last_fps_tick_ms = now_ms();
    a.last_persistent_metrics_ms = a.last_fps_tick_ms;
    a.last_ip_check_ms = 0;
    if (a.debug_enabled) {
        char metal_device[256] = {0};
        (void)tb_bc7_renderer_copy_device_name(metal_device, sizeof(metal_device));
        fprintf(stderr,
                "[diag] event=startup version=%s build=%s commit=%s metalDevice=\"%s\" "
                "supportsBC7=%s supportsRawNV12=true port=%d\n",
                TB_RECEIVER_VERSION,
                TB_RECEIVER_BUILD,
                TB_RECEIVER_COMMIT,
                metal_device,
                tb_disp_supports_bc7(a.disp) ? "true" : "false",
                TB_PORT);
    }

    const char *shutdown_reason = "normal_exit";
    while (!g_term) {
        unsigned int disp_actions = tb_disp_poll_actions(a.disp);
        int socket_activity = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        if (disp_actions & TB_DISP_ACTION_QUIT) {
            shutdown_reason = "local_quit";
            break;
        }
        if ((disp_actions & TB_DISP_ACTION_CYCLE_LANGUAGE) && a.client_fd < 0) {
            tb_receiver_cycle_language_preference(&a);
        }

        uint64_t t = now_ms();
        if (a.last_loop_ms != 0 && t >= a.last_loop_ms) {
            const uint64_t loop_lag_ms = t - a.last_loop_ms;
            if (loop_lag_ms > a.max_loop_lag_ms) {
                a.max_loop_lag_ms = loop_lag_ms;
            }
        }
        a.last_loop_ms = t;
        if (g_monotonic_clock_errno != 0) {
            if (!a.clock_error_logged) {
                char fields[128];
                snprintf(
                    fields,
                    sizeof(fields),
                    "\"errno\":%d",
                    g_monotonic_clock_errno);
                tb_receiver_diagnostics_log(
                    &a.diagnostics,
                    t,
                    "clock_error",
                    fields);
                a.clock_error_logged = 1;
            }
        } else {
            a.clock_error_logged = 0;
        }

        if (t - a.last_ip_check_ms >= 1000) {
            char refreshed_tb_ip[64] = {0};
            char refreshed_net_ip[64] = {0};
            a.last_ip_check_ms = t;
            (void)tb_net_get_tb_ip(refreshed_tb_ip, sizeof(refreshed_tb_ip));
            (void)tb_net_get_lan_ip(refreshed_net_ip, sizeof(refreshed_net_ip));

            const int have_refreshed_ip = refreshed_tb_ip[0] || refreshed_net_ip[0];
            const char *preferred_ip = refreshed_tb_ip[0] ? refreshed_tb_ip
                                     : (refreshed_net_ip[0] ? refreshed_net_ip
                                     : tb_i18n_get("receiver.network.not_detected"));
            if (strcmp(a.tb_ip_text, refreshed_tb_ip) != 0 ||
                strcmp(a.net_ip_text, refreshed_net_ip) != 0 ||
                strcmp(a.ip_text, preferred_ip) != 0) {
                snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", refreshed_tb_ip);
                snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", refreshed_net_ip);
                snprintf(a.ip_text, sizeof(a.ip_text), "%s", preferred_ip);
                build_display_host(a.display_host, sizeof(a.display_host), preferred_ip, have_refreshed_ip);
                if (refreshed_tb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Thunderbolt Bridge IP = %s\n", refreshed_tb_ip);
                }
                if (refreshed_net_ip[0] != '\0') {
                    fprintf(stderr, "[main] Local network IP = %s\n", refreshed_net_ip);
                }
                bonjour_update(&a, TB_PORT);
            }
        }

        /* Accept new client */
        if (a.client_fd < 0) {
            int c = tb_net_accept(a.server_fd);
            if (c >= 0) {
                a.client_fd = c;
                a.have_video_frame = 0;
                a.session_active = 0;
                a.bc7_render_ack_sent = 0;
                a.bc7_render_generation = 0;
                a.bc7_last_keyframe_request_ms = 0;
                a.bc7_keyframe_request_pending = 0;
                a.raw_keyframe_request_pending = 0;
                a.raw_last_keyframe_request_ms = 0;
                reset_bc7_delta_state(&a);
                reset_raw_state(&a);
                a.frames = 0;
                a.last_fps_count = 0;
                a.last_presented_count = 0;
                a.received_bytes = 0;
                a.last_debug_bytes = 0;
                a.packets_received = 0;
                a.bc7_frames = 0;
                a.bc7_bytes = 0;
                a.bc7_invalid_frames = 0;
                a.bc7_render_failures = 0;
                a.bc7_ack_requests = 0;
                a.bc7_acks_sent = 0;
                a.bc7_delta_frames = 0;
                a.bc7_compressed_packets = 0;
                a.bc7_decompression_failures = 0;
                a.bc7_compressed_block_bytes = 0;
                a.bc7_raw_block_bytes = 0;
                a.bc7_keyframe_requests = 0;
                a.raw_full_frames = 0;
                a.raw_region_frames = 0;
                a.bc7_last_packet_ns = 0;
                a.bc7_last_present_ns = 0;
                a.bc7_presented_frames = 0;
                a.bc7_coalesced_frames = 0;
                memset(&a.bc7_packet_interval_ns, 0, sizeof(a.bc7_packet_interval_ns));
                memset(&a.bc7_apply_ns, 0, sizeof(a.bc7_apply_ns));
                memset(&a.bc7_upload_ns, 0, sizeof(a.bc7_upload_ns));
                memset(&a.bc7_present_ns, 0, sizeof(a.bc7_present_ns));
                memset(&a.bc7_present_interval_ns, 0, sizeof(a.bc7_present_interval_ns));
                memset(&a.bc7_decompression_ns, 0, sizeof(a.bc7_decompression_ns));
                memset(&a.bc7_inverse_transform_ns, 0, sizeof(a.bc7_inverse_transform_ns));
                memset(&a.raw_shadow_commit_ns, 0, sizeof(a.raw_shadow_commit_ns));
                memset(&a.raw_upload_ns, 0, sizeof(a.raw_upload_ns));
                memset(&a.raw_checksum_ns, 0, sizeof(a.raw_checksum_ns));
                snprintf(a.active_transport, sizeof(a.active_transport), "%s", "none");
                a.last_recv_ms = t;
                a.last_packet_ms = t;
                a.last_packet_type = 0;
                a.last_heartbeat_sequence = 0;
                a.last_heartbeat_sequence_valid = 0;
                a.heartbeat_ack_send_error = 0;
                a.last_loop_ms = t;
                a.max_loop_lag_ms = 0;
                a.last_persistent_metrics_ms = t;
                SDL_DisableScreenSaver();
                fprintf(stderr, "[main] client connected\n");
                char fields[256];
                snprintf(
                    fields,
                    sizeof(fields),
                    "\"tcpState\":%d,\"thunderboltIP\":\"%s\","
                    "\"localNetworkIP\":\"%s\"",
                    tcp_state_for_fd(a.client_fd),
                    a.tb_ip_text,
                    a.net_ip_text);
                tb_receiver_diagnostics_log(
                    &a.diagnostics,
                    t,
                    "session_start",
                    fields);
                tb_parser_free(&a.parser);
                tb_parser_init(&a.parser, on_packet, &a);
                tb_receiver_refresh_input_capture(&a);
                send_receiver_info(&a);
            }
        } else {
            int drain_error = 0;
            int drain_result = drain_socket(&a, &drain_error);
            if (a.heartbeat_ack_send_error != 0) {
                const int ack_error = a.heartbeat_ack_send_error;
                a.heartbeat_ack_send_error = 0;
                const uint64_t close_time_ms = now_ms();
                close_client(
                    &a,
                    TB_RECEIVER_CLOSE_HEARTBEAT_ACK_ERROR,
                    ack_error,
                    close_time_ms,
                    close_time_ms >= a.last_recv_ms
                        ? close_time_ms - a.last_recv_ms
                        : 0);
            } else if (drain_result == TB_DRAIN_PEER_FIN) {
                close_client(
                    &a,
                    TB_RECEIVER_CLOSE_PEER_FIN,
                    0,
                    t,
                    t >= a.last_recv_ms ? t - a.last_recv_ms : 0);
            } else if (drain_result == TB_DRAIN_READ_ERROR) {
                close_client(
                    &a,
                    TB_RECEIVER_CLOSE_READ_ERROR,
                    drain_error,
                    t,
                    t >= a.last_recv_ms ? t - a.last_recv_ms : 0);
            } else if (drain_result == TB_DRAIN_PARSER_ERROR) {
                close_client(
                    &a,
                    TB_RECEIVER_CLOSE_PARSER_ERROR,
                    0,
                    t,
                    t >= a.last_recv_ms ? t - a.last_recv_ms : 0);
            } else {
                socket_activity = drain_result;
                if (drain_result > 0) a.last_recv_ms = t;
                if (a.close_requested) {
                    close_client(
                        &a,
                        TB_RECEIVER_CLOSE_SENDER_TEARDOWN,
                        0,
                        t,
                        0);
                } else {
                    uint64_t idle_ms = 0;
                    const enum tb_receiver_idle_decision idle_decision =
                        tb_receiver_idle_decision(
                            t,
                            a.last_recv_ms,
                            TB_SENDER_IDLE_TIMEOUT_MS,
                            &idle_ms);
                    if (idle_decision ==
                        TB_RECEIVER_IDLE_CLOCK_REGRESSION) {
                        char fields[256];
                        snprintf(
                            fields,
                            sizeof(fields),
                            "\"nowMs\":%llu,\"lastReceiveMs\":%llu",
                            (unsigned long long)t,
                            (unsigned long long)a.last_recv_ms);
                        tb_receiver_diagnostics_log(
                            &a.diagnostics,
                            t,
                            "clock_regression",
                            fields);
                        a.last_recv_ms = t;
                    } else if (idle_decision ==
                               TB_RECEIVER_IDLE_TIMEOUT) {
                        /* The sender streams frames continuously and heartbeats
                         * every 2s. Total silence means it died without a FIN
                         * (crash, pulled cable, force sleep). Without this
                         * reap, the dead fd is held forever and — because the
                         * receiver is single-client — every future connect is
                         * locked out until the app is restarted. */
                        fprintf(
                            stderr,
                            "[main] no data from sender for %llu ms; "
                            "closing stale session\n",
                            (unsigned long long)idle_ms);
                        close_client(
                            &a,
                            TB_RECEIVER_CLOSE_IDLE_TIMEOUT,
                            0,
                            t,
                            idle_ms);
                    }
                }
            }
        }

        present_pending_bc7(&a);

        if (t - a.last_permissions_poll_ms >= 250) {
            a.last_permissions_poll_ms = t;
            tb_receiver_poll_permissions(&a);
        }

        if (a.client_fd < 0 || !a.session_active) {
            /* No client, or a connection that hasn't started a real streaming
             * session (e.g. a transient UI-language push during discovery):
             * stay on the windowed waiting screen, don't flash fullscreen. */
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text, a.panel_text, a.mode_text, a.language_text, a.permissions_text);
        } else if (!a.have_video_frame) {
            tb_disp_render_connecting(a.disp);
        }

        if (strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0) {
            if (t - a.last_clipboard_poll_ms >= 100) {
                a.last_clipboard_poll_ms = t;
                tb_receiver_send_clipboard_if_changed(&a);
            }
            struct tb_input_event input_event;
            while (tb_disp_pop_input_event(a.disp, &input_event)) {
                switch (input_event.kind) {
                case TB_INPUT_EVENT_MOVE:
                    tb_receiver_send_input_event(&a, "move", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DRAG:
                    tb_receiver_send_input_event(&a, "leftDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DRAG:
                    tb_receiver_send_input_event(&a, "rightDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DRAG:
                    tb_receiver_send_input_event(&a, "otherDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_SCROLL:
                    tb_receiver_send_input_event(&a, "scroll", 0, 0, 0, 0, 1, input_event.scroll_x, 1, input_event.scroll_y, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DOWN:
                    tb_receiver_send_input_event(&a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_UP:
                    tb_receiver_send_input_event(&a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DOWN:
                    tb_receiver_send_input_event(&a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_UP:
                    tb_receiver_send_input_event(&a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DOWN:
                    tb_receiver_send_input_event(&a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_UP:
                    tb_receiver_send_input_event(&a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_KEY_DOWN:
                    tb_receiver_send_input_event(&a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_KEY_UP:
                    tb_receiver_send_input_event(&a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_TARGET:
                    tb_receiver_send_target_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_TARGET:
                    tb_receiver_send_target_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_SPACE:
                    tb_receiver_send_space_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_SPACE:
                    tb_receiver_send_space_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_DEACTIVATE_CONTROL:
                    tb_receiver_send_deactivate_control(&a);
                    break;
                case TB_INPUT_EVENT_NONE:
                default:
                    break;
                }
            }
        }

        /* FPS log */
        if (t - a.last_fps_tick_ms >= 1000) {
            uint64_t df = a.frames - a.last_fps_count;
            uint64_t dpf = a.bc7_presented_frames - a.last_presented_count;
            uint64_t db = a.received_bytes - a.last_debug_bytes;
            uint64_t elapsed_ms = t - a.last_fps_tick_ms;
            a.last_fps_count   = a.frames;
            a.last_presented_count = a.bc7_presented_frames;
            a.last_debug_bytes = a.received_bytes;
            a.last_fps_tick_ms = t;
            double fps = elapsed_ms > 0
                ? ((double)df * 1000.0 / (double)elapsed_ms)
                : 0.0;
            double present_fps = elapsed_ms > 0
                ? ((double)dpf * 1000.0 / (double)elapsed_ms)
                : 0.0;
            double gbps = elapsed_ms > 0
                ? ((double)db * 8.0 / ((double)elapsed_ms * 1000000.0))
                : 0.0;
            int metrics_send_error = 0;
            if (send_receiver_metrics(&a, fps, present_fps, gbps) != 0) {
                metrics_send_error = errno != 0 ? errno : EIO;
            }
            if (t >= a.last_persistent_metrics_ms &&
                t - a.last_persistent_metrics_ms >=
                TB_RECEIVER_DIAGNOSTIC_METRICS_INTERVAL_MS) {
                const uint64_t last_receive_age_ms =
                    t >= a.last_recv_ms ? t - a.last_recv_ms : 0;
                char heartbeat_sequence[32];
                if (a.last_heartbeat_sequence_valid) {
                    snprintf(
                        heartbeat_sequence,
                        sizeof(heartbeat_sequence),
                        "%llu",
                        (unsigned long long)a.last_heartbeat_sequence);
                } else {
                    snprintf(
                        heartbeat_sequence,
                        sizeof(heartbeat_sequence),
                        "%s",
                        "null");
                }
                char fields[1536];
                snprintf(
                    fields,
                    sizeof(fields),
                    "\"connected\":%s,\"sessionActive\":%s,"
                    "\"transport\":\"%s\",\"fps\":%.3f,"
                    "\"presentFPS\":%.3f,\"networkGbps\":%.6f,"
                    "\"frames\":%llu,\"packets\":%llu,\"bytes\":%llu,"
                    "\"lastReceiveAgeMs\":%llu,\"lastPacketType\":%u,"
                    "\"lastPacketAgeMs\":%llu,\"lastHeartbeatSequence\":%s,"
                    "\"tcpState\":%d,\"invalidFrames\":%llu,"
                    "\"renderFailures\":%llu,\"appliedSequence\":%llu,"
                    "\"keyframeRequests\":%llu",
                    a.client_fd >= 0 ? "true" : "false",
                    a.session_active ? "true" : "false",
                    a.active_transport,
                    fps,
                    present_fps,
                    gbps,
                    (unsigned long long)a.frames,
                    (unsigned long long)a.packets_received,
                    (unsigned long long)a.received_bytes,
                    (unsigned long long)last_receive_age_ms,
                    (unsigned int)a.last_packet_type,
                    (unsigned long long)(
                        t >= a.last_packet_ms
                            ? t - a.last_packet_ms
                            : 0),
                    heartbeat_sequence,
                    tcp_state_for_fd(a.client_fd),
                    (unsigned long long)a.bc7_invalid_frames,
                    (unsigned long long)a.bc7_render_failures,
                    (unsigned long long)a.bc7_applied_sequence,
                    (unsigned long long)a.bc7_keyframe_requests);
                tb_receiver_diagnostics_log(
                    &a.diagnostics,
                    t,
                    "metrics",
                    fields);
                a.last_persistent_metrics_ms = t;
            }
            if (a.debug_enabled) {
                const struct tb_metric_summary packet_interval =
                    metric_summary(&a.bc7_packet_interval_ns);
                const struct tb_metric_summary apply =
                    metric_summary(&a.bc7_apply_ns);
                const struct tb_metric_summary upload =
                    metric_summary(&a.bc7_upload_ns);
                const struct tb_metric_summary present =
                    metric_summary(&a.bc7_present_ns);
                const struct tb_metric_summary present_interval =
                    metric_summary(&a.bc7_present_interval_ns);
                const struct tb_metric_summary decompression =
                    metric_summary(&a.bc7_decompression_ns);
                const struct tb_metric_summary inverse_transform =
                    metric_summary(&a.bc7_inverse_transform_ns);
                fprintf(stderr,
                        "[diag] event=metrics connected=%s sessionActive=%s "
                        "transport=%s fps=%.2f presentFps=%.2f networkGbps=%.3f packets=%llu "
                        "bc7Frames=%llu bc7PayloadBytes=%llu bc7Invalid=%llu "
                        "renderFailures=%llu generation=%u ackPending=%s "
                        "bc7Deltas=%llu appliedSequence=%llu keyframeRequests=%llu "
                        "ackRequests=%llu acksSent=%llu presented=%llu coalesced=%llu "
                        "packetIntervalMs=%.2f/%.2f/%.2f applyMs=%.2f/%.2f/%.2f "
                        "uploadMs=%.2f/%.2f/%.2f presentMs=%.2f/%.2f/%.2f "
                        "presentIntervalMs=%.2f/%.2f/%.2f compressed=%llu "
                        "compressionRatio=%.3f decompressionFailures=%llu "
                        "decompressionMs=%.2f/%.2f/%.2f "
                        "inverseMs=%.2f/%.2f/%.2f\n",
                        a.client_fd >= 0 ? "true" : "false",
                        a.session_active ? "true" : "false",
                        a.active_transport,
                        fps,
                        present_fps,
                        gbps,
                        (unsigned long long)a.packets_received,
                        (unsigned long long)a.bc7_frames,
                        (unsigned long long)a.bc7_bytes,
                        (unsigned long long)a.bc7_invalid_frames,
                        (unsigned long long)a.bc7_render_failures,
                        a.bc7_render_generation,
                        (a.bc7_render_generation != 0 && !a.bc7_render_ack_sent) ? "true" : "false",
                        (unsigned long long)a.bc7_delta_frames,
                        (unsigned long long)a.bc7_applied_sequence,
                        (unsigned long long)a.bc7_keyframe_requests,
                        (unsigned long long)a.bc7_ack_requests,
                        (unsigned long long)a.bc7_acks_sent,
                        (unsigned long long)a.bc7_presented_frames,
                        (unsigned long long)a.bc7_coalesced_frames,
                        ns_to_ms(packet_interval.p50),
                        ns_to_ms(packet_interval.p95),
                        ns_to_ms(packet_interval.p99),
                        ns_to_ms(apply.p50),
                        ns_to_ms(apply.p95),
                        ns_to_ms(apply.p99),
                        ns_to_ms(upload.p50),
                        ns_to_ms(upload.p95),
                        ns_to_ms(upload.p99),
                        ns_to_ms(present.p50),
                        ns_to_ms(present.p95),
                        ns_to_ms(present.p99),
                        ns_to_ms(present_interval.p50),
                        ns_to_ms(present_interval.p95),
                        ns_to_ms(present_interval.p99),
                        (unsigned long long)a.bc7_compressed_packets,
                        a.bc7_raw_block_bytes > 0
                            ? (double)a.bc7_compressed_block_bytes /
                                (double)a.bc7_raw_block_bytes
                            : 1.0,
                        (unsigned long long)a.bc7_decompression_failures,
                        ns_to_ms(decompression.p50),
                        ns_to_ms(decompression.p95),
                        ns_to_ms(decompression.p99),
                        ns_to_ms(inverse_transform.p50),
                        ns_to_ms(inverse_transform.p95),
                        ns_to_ms(inverse_transform.p99));
            } else if (df > 0) {
                fprintf(stderr, "[main] %llu fps\n", (unsigned long long)df);
            }
            if (metrics_send_error != 0 && a.client_fd >= 0) {
                close_client(
                    &a,
                    TB_RECEIVER_CLOSE_METRICS_SEND_ERROR,
                    metrics_send_error,
                    t,
                    t >= a.last_recv_ms ? t - a.last_recv_ms : 0);
            }
        }

        /* Keep connected streaming latency unchanged, but do not poll and
         * repaint a static disconnected/connecting window at ~1000 Hz. */
        const uint32_t loop_delay_ms = tb_receiver_loop_delay_ms(
            a.client_fd >= 0,
            a.have_video_frame,
            socket_activity
        );
        if (loop_delay_ms > 0) SDL_Delay(loop_delay_ms);
    }

    if (g_term) shutdown_reason = "signal_shutdown";
    if (a.client_fd >= 0) {
        close_client(
            &a,
            g_term
                ? TB_RECEIVER_CLOSE_SIGNAL_SHUTDOWN
                : TB_RECEIVER_CLOSE_LOCAL_QUIT,
            0,
            now_ms(),
            0);
    }
    tb_receiver_stop_input_tap(&a);
    if (a.server_fd >= 0) close(a.server_fd);
    bonjour_deinit(&a);
    tb_parser_free(&a.parser);
    tb_dec_destroy(a.dec);
    if (a.audio_device != 0) {
        SDL_CloseAudioDevice(a.audio_device);
    }
    tb_disp_destroy(a.disp);
    tb_receiver_diagnostics_close(
        &a.diagnostics,
        now_ms(),
        shutdown_reason);
    fprintf(stderr, "[main] bye\n");
    return 0;
}
