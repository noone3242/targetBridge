#ifndef TB_RECEIVER_HEARTBEAT_H
#define TB_RECEIVER_HEARTBEAT_H

#include <stddef.h>
#include <stdint.h>

struct tb_heartbeat_request {
    uint64_t sequence;
    uint64_t sender_timestamp_ms;
    int has_sender_timestamp;
};

int tb_heartbeat_parse_request(
    const uint8_t *payload,
    size_t payload_length,
    struct tb_heartbeat_request *request);

int tb_heartbeat_build_ack(
    char *buffer,
    size_t buffer_size,
    const struct tb_heartbeat_request *request,
    uint64_t receiver_timestamp_ms,
    const char *process_instance_id,
    uint64_t event_loop_lag_ms,
    uint64_t applied_sequence);

int tb_heartbeat_build_ack_packet(
    uint8_t *packet,
    size_t packet_capacity,
    const struct tb_heartbeat_request *request,
    uint64_t receiver_timestamp_ms,
    const char *process_instance_id,
    uint64_t event_loop_lag_ms,
    uint64_t applied_sequence);

#endif
