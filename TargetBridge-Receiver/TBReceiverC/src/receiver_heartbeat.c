#include "receiver_heartbeat.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#define TB_HEARTBEAT_PACKET_TYPE 0x30u

static int tb_extract_json_uint64(
    const uint8_t *payload,
    size_t payload_length,
    const char *key,
    uint64_t *value) {
    if (!payload || !key || !value) return 0;
    const size_t key_length = strlen(key);
    if (key_length == 0 || key_length > payload_length) return 0;

    for (size_t index = 0; index + key_length <= payload_length; index++) {
        if (memcmp(payload + index, key, key_length) != 0) continue;
        size_t cursor = index + key_length;
        while (cursor < payload_length &&
               isspace((unsigned char)payload[cursor])) {
            cursor++;
        }
        if (cursor >= payload_length || payload[cursor] != ':') return 0;
        cursor++;
        while (cursor < payload_length &&
               isspace((unsigned char)payload[cursor])) {
            cursor++;
        }
        if (cursor >= payload_length ||
            payload[cursor] < '0' ||
            payload[cursor] > '9') {
            return 0;
        }

        uint64_t parsed = 0;
        do {
            const uint64_t digit = (uint64_t)(payload[cursor] - '0');
            if (parsed > (UINT64_MAX - digit) / 10u) return 0;
            parsed = parsed * 10u + digit;
            cursor++;
        } while (cursor < payload_length &&
                 payload[cursor] >= '0' &&
                 payload[cursor] <= '9');
        *value = parsed;
        return 1;
    }
    return 0;
}

int tb_heartbeat_parse_request(
    const uint8_t *payload,
    size_t payload_length,
    struct tb_heartbeat_request *request) {
    if (!request) return -1;
    memset(request, 0, sizeof(*request));
    if (!tb_extract_json_uint64(
            payload,
            payload_length,
            "\"sequence\"",
            &request->sequence)) {
        return -1;
    }
    request->has_sender_timestamp = tb_extract_json_uint64(
        payload,
        payload_length,
        "\"senderTimestampMs\"",
        &request->sender_timestamp_ms);
    return 0;
}

int tb_heartbeat_build_ack(
    char *buffer,
    size_t buffer_size,
    const struct tb_heartbeat_request *request,
    uint64_t receiver_timestamp_ms,
    const char *process_instance_id,
    uint64_t event_loop_lag_ms,
    uint64_t applied_sequence) {
    if (!buffer || buffer_size == 0 || !request) return -1;
    const char *instance =
        process_instance_id && *process_instance_id
            ? process_instance_id
            : "unknown";
    const int length = request->has_sender_timestamp
        ? snprintf(
              buffer,
              buffer_size,
              "{\"sequence\":%llu,\"ack\":true,"
              "\"senderTimestampMs\":%llu,\"receiverTimestampMs\":%llu,"
              "\"processInstanceID\":\"%s\",\"eventLoopLagMs\":%llu,"
              "\"appliedSequence\":%llu}",
              (unsigned long long)request->sequence,
              (unsigned long long)request->sender_timestamp_ms,
              (unsigned long long)receiver_timestamp_ms,
              instance,
              (unsigned long long)event_loop_lag_ms,
              (unsigned long long)applied_sequence)
        : snprintf(
              buffer,
              buffer_size,
              "{\"sequence\":%llu,\"ack\":true,"
              "\"receiverTimestampMs\":%llu,"
              "\"processInstanceID\":\"%s\",\"eventLoopLagMs\":%llu,"
              "\"appliedSequence\":%llu}",
              (unsigned long long)request->sequence,
              (unsigned long long)receiver_timestamp_ms,
              instance,
              (unsigned long long)event_loop_lag_ms,
              (unsigned long long)applied_sequence);
    return length > 0 && (size_t)length < buffer_size ? length : -1;
}

int tb_heartbeat_build_ack_packet(
    uint8_t *packet,
    size_t packet_capacity,
    const struct tb_heartbeat_request *request,
    uint64_t receiver_timestamp_ms,
    const char *process_instance_id,
    uint64_t event_loop_lag_ms,
    uint64_t applied_sequence) {
    if (!packet || packet_capacity < 6u) return -1;
    const int json_length = tb_heartbeat_build_ack(
        (char *)packet + 5,
        packet_capacity - 5u,
        request,
        receiver_timestamp_ms,
        process_instance_id,
        event_loop_lag_ms,
        applied_sequence);
    if (json_length <= 0) return -1;
    const uint32_t framed_length = 1u + (uint32_t)json_length;
    packet[0] = (uint8_t)(framed_length >> 24);
    packet[1] = (uint8_t)(framed_length >> 16);
    packet[2] = (uint8_t)(framed_length >> 8);
    packet[3] = (uint8_t)framed_length;
    packet[4] = TB_HEARTBEAT_PACKET_TYPE;
    return 5 + json_length;
}
