#ifndef TB_RECEIVER_DIAGNOSTICS_H
#define TB_RECEIVER_DIAGNOSTICS_H

#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#define TB_RECEIVER_DIAGNOSTIC_METRICS_INTERVAL_MS 10000ULL

enum tb_receiver_close_reason {
    TB_RECEIVER_CLOSE_PEER_FIN = 0,
    TB_RECEIVER_CLOSE_READ_ERROR,
    TB_RECEIVER_CLOSE_PARSER_ERROR,
    TB_RECEIVER_CLOSE_SENDER_TEARDOWN,
    TB_RECEIVER_CLOSE_IDLE_TIMEOUT,
    TB_RECEIVER_CLOSE_METRICS_SEND_ERROR,
    TB_RECEIVER_CLOSE_LOCAL_QUIT,
    TB_RECEIVER_CLOSE_SIGNAL_SHUTDOWN
};

enum tb_receiver_idle_decision {
    TB_RECEIVER_IDLE_ACTIVE = 0,
    TB_RECEIVER_IDLE_TIMEOUT,
    TB_RECEIVER_IDLE_CLOCK_REGRESSION
};

static inline const char *tb_receiver_close_reason_name(
    enum tb_receiver_close_reason reason) {
    switch (reason) {
    case TB_RECEIVER_CLOSE_PEER_FIN:
        return "peer_fin";
    case TB_RECEIVER_CLOSE_READ_ERROR:
        return "read_error";
    case TB_RECEIVER_CLOSE_PARSER_ERROR:
        return "parser_error";
    case TB_RECEIVER_CLOSE_SENDER_TEARDOWN:
        return "sender_teardown";
    case TB_RECEIVER_CLOSE_IDLE_TIMEOUT:
        return "idle_timeout";
    case TB_RECEIVER_CLOSE_METRICS_SEND_ERROR:
        return "metrics_send_error";
    case TB_RECEIVER_CLOSE_LOCAL_QUIT:
        return "local_quit";
    case TB_RECEIVER_CLOSE_SIGNAL_SHUTDOWN:
        return "signal_shutdown";
    }
    return "unknown";
}

static inline enum tb_receiver_idle_decision tb_receiver_idle_decision(
    uint64_t now_ms,
    uint64_t last_recv_ms,
    uint64_t timeout_ms,
    uint64_t *idle_ms) {
    if (now_ms < last_recv_ms) {
        if (idle_ms) *idle_ms = 0;
        return TB_RECEIVER_IDLE_CLOCK_REGRESSION;
    }
    const uint64_t elapsed = now_ms - last_recv_ms;
    if (idle_ms) *idle_ms = elapsed;
    return elapsed >= timeout_ms
        ? TB_RECEIVER_IDLE_TIMEOUT
        : TB_RECEIVER_IDLE_ACTIVE;
}

struct tb_receiver_diagnostics {
    FILE *file;
    char log_path[PATH_MAX];
    char previous_log_path[PATH_MAX];
    char run_state_path[PATH_MAX];
    char process_instance_id[192];
    uint64_t startup_monotonic_ms;
    int initialized;
};

int tb_receiver_diagnostics_init(
    struct tb_receiver_diagnostics *diagnostics,
    const char *version,
    const char *build,
    const char *commit,
    uint64_t startup_monotonic_ms);

void tb_receiver_diagnostics_log(
    struct tb_receiver_diagnostics *diagnostics,
    uint64_t monotonic_ms,
    const char *event,
    const char *fields_json);

void tb_receiver_diagnostics_flush(
    struct tb_receiver_diagnostics *diagnostics,
    int sync_to_disk);

void tb_receiver_diagnostics_close(
    struct tb_receiver_diagnostics *diagnostics,
    uint64_t monotonic_ms,
    const char *exit_reason);

#endif
