#include "receiver_teardown.h"

#include <stdio.h>
#include <string.h>

#define TB_TEARDOWN_PACKET_TYPE 0x31u

static int tb_json_escape(
    char *destination,
    size_t destination_size,
    const char *source) {
    if (!destination || destination_size == 0) return -1;
    size_t written = 0;
    for (const unsigned char *p =
             (const unsigned char *)(source ? source : "");
         *p;
         p++) {
        const char *escape = NULL;
        switch (*p) {
        case '"':
            escape = "\\\"";
            break;
        case '\\':
            escape = "\\\\";
            break;
        case '\n':
            escape = "\\n";
            break;
        case '\r':
            escape = "\\r";
            break;
        case '\t':
            escape = "\\t";
            break;
        default:
            break;
        }
        if (escape) {
            const size_t length = strlen(escape);
            if (written + length >= destination_size) return -1;
            memcpy(destination + written, escape, length);
            written += length;
        } else {
            if (written + 1u >= destination_size) return -1;
            destination[written++] = (char)*p;
        }
    }
    destination[written] = '\0';
    return 0;
}

int tb_teardown_build_packet(
    uint8_t *packet,
    size_t packet_capacity,
    const struct tb_teardown_signal *signal) {
    if (!packet || packet_capacity < 6u || !signal || !signal->reason) {
        return -1;
    }
    char reason[128];
    char origin[32];
    char category[32];
    char detail[384];
    char process_instance_id[256];
    char session_id[128];
    if (tb_json_escape(reason, sizeof(reason), signal->reason) != 0 ||
        tb_json_escape(origin, sizeof(origin), signal->origin) != 0 ||
        tb_json_escape(category, sizeof(category), signal->category) != 0 ||
        tb_json_escape(detail, sizeof(detail), signal->detail) != 0 ||
        tb_json_escape(
            process_instance_id,
            sizeof(process_instance_id),
            signal->process_instance_id) != 0 ||
        tb_json_escape(
            session_id,
            sizeof(session_id),
            signal->session_id) != 0) {
        return -1;
    }
    const int json_length = snprintf(
        (char *)packet + 5,
        packet_capacity - 5u,
        "{\"reason\":\"%s\",\"origin\":\"%s\","
        "\"category\":\"%s\",\"detail\":\"%s\",\"errno\":%d,"
        "\"timestampMs\":%llu,\"processInstanceID\":\"%s\","
        "\"sessionID\":\"%s\",\"frames\":%llu,\"packets\":%llu,"
        "\"bytes\":%llu}",
        reason,
        origin,
        category,
        detail,
        signal->error_code,
        (unsigned long long)signal->timestamp_ms,
        process_instance_id,
        session_id,
        (unsigned long long)signal->frames,
        (unsigned long long)signal->packets,
        (unsigned long long)signal->bytes);
    if (json_length <= 0 ||
        (size_t)json_length >= packet_capacity - 5u) {
        return -1;
    }
    const uint32_t framed_length = 1u + (uint32_t)json_length;
    packet[0] = (uint8_t)(framed_length >> 24);
    packet[1] = (uint8_t)(framed_length >> 16);
    packet[2] = (uint8_t)(framed_length >> 8);
    packet[3] = (uint8_t)framed_length;
    packet[4] = TB_TEARDOWN_PACKET_TYPE;
    return 5 + json_length;
}
