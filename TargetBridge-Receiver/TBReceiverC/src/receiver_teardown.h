#ifndef TB_RECEIVER_TEARDOWN_H
#define TB_RECEIVER_TEARDOWN_H

#include <stddef.h>
#include <stdint.h>

struct tb_teardown_signal {
    const char *reason;
    const char *origin;
    const char *category;
    const char *detail;
    int error_code;
    uint64_t timestamp_ms;
    const char *process_instance_id;
    const char *session_id;
    uint64_t frames;
    uint64_t packets;
    uint64_t bytes;
};

int tb_teardown_build_packet(
    uint8_t *packet,
    size_t packet_capacity,
    const struct tb_teardown_signal *signal);

#endif
