#include "receiver_diagnostics.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define TB_RECEIVER_LOG_MAX_BYTES (8ULL * 1024ULL * 1024ULL)

static int tb_mkdir_if_needed(const char *path) {
    if (mkdir(path, 0755) == 0 || errno == EEXIST) return 0;
    return -1;
}

static void tb_json_escape(FILE *file, const char *text) {
    if (!file) return;
    for (const unsigned char *p = (const unsigned char *)(text ? text : "");
         *p;
         p++) {
        switch (*p) {
        case '"':
            fputs("\\\"", file);
            break;
        case '\\':
            fputs("\\\\", file);
            break;
        case '\b':
            fputs("\\b", file);
            break;
        case '\f':
            fputs("\\f", file);
            break;
        case '\n':
            fputs("\\n", file);
            break;
        case '\r':
            fputs("\\r", file);
            break;
        case '\t':
            fputs("\\t", file);
            break;
        default:
            if (*p < 0x20) {
                fprintf(file, "\\u%04x", (unsigned int)*p);
            } else {
                fputc(*p, file);
            }
            break;
        }
    }
}

static void tb_timestamp(char *buffer, size_t size) {
    struct timespec ts = {0};
    struct tm tm_now = {0};
    if (!buffer || size == 0) return;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0 ||
        localtime_r(&ts.tv_sec, &tm_now) == NULL) {
        snprintf(buffer, size, "unknown");
        return;
    }
    char base[40];
    strftime(base, sizeof(base), "%Y-%m-%dT%H:%M:%S", &tm_now);
    char zone[8];
    strftime(zone, sizeof(zone), "%z", &tm_now);
    snprintf(
        buffer,
        size,
        "%s.%03ld%s",
        base,
        ts.tv_nsec / 1000000L,
        zone);
}

static int tb_read_previous_unclean(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char buffer[1024];
    const size_t count = fread(buffer, 1, sizeof(buffer) - 1u, file);
    fclose(file);
    buffer[count] = '\0';
    return strstr(buffer, "\"cleanExit\":false") != NULL;
}

static int tb_write_run_state(
    const struct tb_receiver_diagnostics *diagnostics,
    int clean_exit,
    const char *exit_reason) {
    if (!diagnostics || !diagnostics->run_state_path[0]) return EINVAL;
    char temporary_path[PATH_MAX];
    if (snprintf(
            temporary_path,
            sizeof(temporary_path),
            "%s.tmp",
            diagnostics->run_state_path) >= (int)sizeof(temporary_path)) {
        return ENAMETOOLONG;
    }
    FILE *file = fopen(temporary_path, "w");
    if (!file) return errno != 0 ? errno : EIO;
    char timestamp[64];
    tb_timestamp(timestamp, sizeof(timestamp));
    fprintf(file, "{\"timestamp\":\"");
    tb_json_escape(file, timestamp);
    fprintf(file, "\",\"processInstanceID\":\"");
    tb_json_escape(file, diagnostics->process_instance_id);
    fprintf(
        file,
        "\",\"cleanExit\":%s,\"exitReason\":\"",
        clean_exit ? "true" : "false");
    tb_json_escape(file, exit_reason ? exit_reason : "");
    fputs("\"}\n", file);
    const int file_descriptor = fileno(file);
    const int flush_result = fflush(file);
    const int sync_result =
        file_descriptor >= 0 ? fsync(file_descriptor) : -1;
    const int close_result = fclose(file);
    if (flush_result != 0 || sync_result != 0 || close_result != 0) {
        const int write_error = errno != 0 ? errno : EIO;
        unlink(temporary_path);
        return write_error;
    }
    if (rename(temporary_path, diagnostics->run_state_path) != 0) {
        const int rename_error = errno != 0 ? errno : EIO;
        unlink(temporary_path);
        return rename_error;
    }
    return 0;
}

static int tb_open_log(struct tb_receiver_diagnostics *diagnostics) {
    diagnostics->file = fopen(diagnostics->log_path, "a");
    if (!diagnostics->file) return -1;
    setvbuf(diagnostics->file, NULL, _IOLBF, 0);
    return 0;
}

static void tb_rotate_if_needed(
    struct tb_receiver_diagnostics *diagnostics) {
    if (!diagnostics || !diagnostics->file) return;
    struct stat info;
    if (fstat(fileno(diagnostics->file), &info) != 0 ||
        (uint64_t)info.st_size < TB_RECEIVER_LOG_MAX_BYTES) {
        return;
    }
    fclose(diagnostics->file);
    diagnostics->file = NULL;
    unlink(diagnostics->previous_log_path);
    if (rename(
            diagnostics->log_path,
            diagnostics->previous_log_path) != 0) {
        fprintf(
            stderr,
            "[diag] cannot rotate full Receiver log: %s\n",
            strerror(errno));
    }
    if (tb_open_log(diagnostics) != 0) {
        fprintf(
            stderr,
            "[diag] cannot reopen Receiver log after rotation: %s\n",
            strerror(errno));
    }
}

int tb_receiver_diagnostics_init(
    struct tb_receiver_diagnostics *diagnostics,
    const char *version,
    const char *build,
    const char *commit,
    uint64_t startup_monotonic_ms) {
    if (!diagnostics) return -1;
    memset(diagnostics, 0, sizeof(*diagnostics));

    const char *home = getenv("HOME");
    if (!home || !*home) {
        fprintf(stderr, "[diag] HOME is unavailable; persistent logging disabled\n");
        return -1;
    }

    char app_dir[PATH_MAX];
    char log_dir[PATH_MAX];
    if (snprintf(
            app_dir,
            sizeof(app_dir),
            "%s/Library/Application Support/TargetBridge Receiver",
            home) >= (int)sizeof(app_dir) ||
        snprintf(log_dir, sizeof(log_dir), "%s/Logs", app_dir) >=
            (int)sizeof(log_dir) ||
        snprintf(
            diagnostics->log_path,
            sizeof(diagnostics->log_path),
            "%s/receiver.jsonl",
            log_dir) >= (int)sizeof(diagnostics->log_path) ||
        snprintf(
            diagnostics->previous_log_path,
            sizeof(diagnostics->previous_log_path),
            "%s/receiver.previous.jsonl",
            log_dir) >= (int)sizeof(diagnostics->previous_log_path) ||
        snprintf(
            diagnostics->run_state_path,
            sizeof(diagnostics->run_state_path),
            "%s/run-state.json",
            log_dir) >= (int)sizeof(diagnostics->run_state_path)) {
        fprintf(stderr, "[diag] persistent log path is too long\n");
        return -1;
    }

    if (tb_mkdir_if_needed(app_dir) != 0 ||
        tb_mkdir_if_needed(log_dir) != 0) {
        fprintf(
            stderr,
            "[diag] cannot create persistent log directory: %s\n",
            strerror(errno));
        return -1;
    }

    const int previous_unclean =
        tb_read_previous_unclean(diagnostics->run_state_path);
    struct stat current_log;
    if (stat(diagnostics->log_path, &current_log) == 0 &&
        current_log.st_size > 0) {
        unlink(diagnostics->previous_log_path);
        if (rename(
                diagnostics->log_path,
                diagnostics->previous_log_path) != 0) {
            fprintf(
                stderr,
                "[diag] cannot rotate previous Receiver log: %s\n",
                strerror(errno));
        }
    }
    if (tb_open_log(diagnostics) != 0) {
        fprintf(
            stderr,
            "[diag] cannot open persistent Receiver log: %s\n",
            strerror(errno));
        return -1;
    }

    diagnostics->startup_monotonic_ms = startup_monotonic_ms;
    snprintf(
        diagnostics->process_instance_id,
        sizeof(diagnostics->process_instance_id),
        "%s-%ld-%llu",
        commit ? commit : "unknown",
        (long)getpid(),
        (unsigned long long)startup_monotonic_ms);
    diagnostics->initialized = 1;
    const int run_state_error =
        tb_write_run_state(diagnostics, 0, "running");

    char fields[768];
    snprintf(
        fields,
        sizeof(fields),
        "\"version\":\"%s\",\"build\":\"%s\",\"commit\":\"%s\","
        "\"pid\":%ld,\"previousRunUnclean\":%s",
        version ? version : "",
        build ? build : "",
        commit ? commit : "",
        (long)getpid(),
        previous_unclean ? "true" : "false");
    tb_receiver_diagnostics_log(
        diagnostics,
        startup_monotonic_ms,
        "process_start",
        fields);
    if (run_state_error != 0) {
        char state_fields[128];
        snprintf(
            state_fields,
            sizeof(state_fields),
            "\"errno\":%d,\"operation\":\"mark_running\"",
            run_state_error);
        tb_receiver_diagnostics_log(
            diagnostics,
            startup_monotonic_ms,
            "run_state_write_error",
            state_fields);
    }
    if (previous_unclean) {
        tb_receiver_diagnostics_log(
            diagnostics,
            startup_monotonic_ms,
            "unclean_previous_run",
            NULL);
    }
    return 0;
}

void tb_receiver_diagnostics_log(
    struct tb_receiver_diagnostics *diagnostics,
    uint64_t monotonic_ms,
    const char *event,
    const char *fields_json) {
    if (!diagnostics || !diagnostics->initialized || !diagnostics->file) return;
    tb_rotate_if_needed(diagnostics);
    if (!diagnostics->file) return;

    char timestamp[64];
    tb_timestamp(timestamp, sizeof(timestamp));
    fputs("{\"timestamp\":\"", diagnostics->file);
    tb_json_escape(diagnostics->file, timestamp);
    fprintf(
        diagnostics->file,
        "\",\"monotonicMs\":%llu,\"processInstanceID\":\"",
        (unsigned long long)monotonic_ms);
    tb_json_escape(diagnostics->file, diagnostics->process_instance_id);
    fputs("\",\"event\":\"", diagnostics->file);
    tb_json_escape(diagnostics->file, event ? event : "unknown");
    fputc('"', diagnostics->file);
    if (fields_json && *fields_json) {
        fputc(',', diagnostics->file);
        fputs(fields_json, diagnostics->file);
    }
    fputs("}\n", diagnostics->file);
}

void tb_receiver_diagnostics_flush(
    struct tb_receiver_diagnostics *diagnostics,
    int sync_to_disk) {
    if (!diagnostics || !diagnostics->file) return;
    (void)fflush(diagnostics->file);
    if (sync_to_disk) {
        const int file_descriptor = fileno(diagnostics->file);
        if (file_descriptor >= 0) (void)fsync(file_descriptor);
    }
}

void tb_receiver_diagnostics_close(
    struct tb_receiver_diagnostics *diagnostics,
    uint64_t monotonic_ms,
    const char *exit_reason) {
    if (!diagnostics || !diagnostics->initialized) return;
    char fields[256];
    snprintf(
        fields,
        sizeof(fields),
        "\"reason\":\"%s\",\"uptimeMs\":%llu",
        exit_reason ? exit_reason : "normal_exit",
        (unsigned long long)(
            monotonic_ms >= diagnostics->startup_monotonic_ms
                ? monotonic_ms - diagnostics->startup_monotonic_ms
                : 0));
    tb_receiver_diagnostics_log(
        diagnostics,
        monotonic_ms,
        "process_exit",
        fields);
    const int run_state_error = tb_write_run_state(
        diagnostics,
        1,
        exit_reason ? exit_reason : "normal_exit");
    if (run_state_error != 0) {
        char state_fields[128];
        snprintf(
            state_fields,
            sizeof(state_fields),
            "\"errno\":%d,\"operation\":\"mark_clean_exit\"",
            run_state_error);
        tb_receiver_diagnostics_log(
            diagnostics,
            monotonic_ms,
            "run_state_write_error",
            state_fields);
    }
    tb_receiver_diagnostics_flush(diagnostics, 1);
    if (diagnostics->file) fclose(diagnostics->file);
    diagnostics->file = NULL;
    diagnostics->initialized = 0;
}
