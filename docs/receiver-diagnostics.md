# Receiver diagnostics

The production Receiver writes persistent JSON Lines diagnostics without
requiring `--debug`.

## Files

```text
~/Library/Application Support/TargetBridge Receiver/Logs/
  receiver.jsonl
  receiver.previous.jsonl
  run-state.json
  input-debug.log
```

- `receiver.jsonl` is the current process log.
- `receiver.previous.jsonl` is the preceding process log or the previous
  8 MiB segment.
- `run-state.json` records whether the preceding process reached a clean exit.
- `input-debug.log` remains the separate input-routing trace.

## Events

The Receiver records:

- `process_start`, `process_exit`, and `unclean_previous_run`
- `session_start` and `session_close`
- `heartbeat_ack_sent`, `heartbeat_ack_error`, and `heartbeat_malformed`
- a bounded `metrics` sample every 10 seconds
- `clock_error`, `clock_regression`, and `run_state_write_error`

`session_close.reason` is one of:

```text
peer_fin
read_error
parser_error
sender_teardown
idle_timeout
metrics_send_error
heartbeat_ack_error
local_quit
signal_shutdown
```

Each close event includes the numeric error, socket error, TCP state,
monotonic receive timestamps, idle duration, last packet type and age, last
heartbeat sequence, transport, and frame/protocol counters.

Current Receivers advertise `supportsHeartbeatAck`. They reply to each
`0x30` heartbeat with the original sequence, sender timestamp, process
instance ID, event-loop lag, and latest applied frame sequence. A compatible
Sender only enables its liveness timeout when that capability is present.

## Sender diagnostics

The Sender also keeps process and session diagnostics:

```text
~/Library/Application Support/TargetBridge/Logs/
  sender.jsonl
  sender.previous.jsonl
  run-state.json
```

Both peers reuse packet type `0x31` for a structured, backward-compatible
close signal. Besides the existing `reason`, the payload can include origin,
category, detail, errno, monotonic timestamp, process instance, session ID,
and bounded counters.

Controlled closes send this signal before cancelling the socket. Received
teardown packets are never echoed. Crashes and force kills cannot send a final
packet; the next process launch records `unclean_previous_run` instead.

## Reading the latest evidence

```bash
tail -n 100 \
  "$HOME/Library/Application Support/TargetBridge Receiver/Logs/receiver.jsonl"

cat \
  "$HOME/Library/Application Support/TargetBridge Receiver/Logs/run-state.json"
```
