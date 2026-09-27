# BC7 Low-Latency Pipeline Design

Date: 2026-09-26

## Scope

Improve the stable native 5K BC7 path without introducing BC1 or changing the
existing BC7 keyframe/delta wire formats. The implementation targets queued
latency and observability rather than claiming that ScreenCaptureKit will
produce 60 complete frames every second.

## Sender scheduling

- Keep one pending captured BC7 frame. A newer capture replaces an older frame
  that has not started encoding.
- Permit only one BC7 network packet in flight. While it is in flight, captured
  frames continue to coalesce in the latest-frame slot.
- Resume encoding from the network completion callback. This prevents several
  5K packets from accumulating in Network.framework and turning congestion into
  visible stale-frame latency.
- A send failure invalidates the delta baseline and forces the next transmitted
  frame to be a keyframe.

## Tile budget and deferral

- The Receiver-visible baseline advances only for tiles included in a packet.
- Dirty tiles beyond the current budget remain dirty and carry an age.
- Older deferred tiles are selected first. The minimum budget is one quarter
  of the framebuffer tile count, so a continuously dirty tile is serviced
  within four transmitted deltas.
- Adjacent selected tiles separated by one unchanged tile are merged into one
  run. This bounds run count without forcing a full 14.75 MB keyframe.
- The budget begins at the complete framebuffer. Two send completions at or
  above 12 ms reduce it by 25%; eight completions at or below 8 ms increase it.
  Four settling samples follow each adjustment.
- Periodic and failure-recovery keyframes remain unchanged.

## Receiver latency path

- BC7 packets are parsed, validated and uploaded while the socket is drained.
  If several complete frames arrive in one event-loop iteration, only the
  newest resulting texture state is presented.
- `CAMetalLayer` remains display-synchronized and uses three drawables.
- Delta checksum validation happens before mutation. Valid deltas then commit
  directly into the persistent shadow buffer, removing the previous full-frame
  shadow allocation and copy on every delta.

## Metrics

Sender logs bounded rolling p50/p95/p99 values for capture callback interval,
capture-to-encode queue age, GPU encode, planning, packet assembly, packet
bytes, dirty tiles and Network.framework completion latency. It also reports
all ScreenCaptureKit frame statuses, the active tile budget, deferred count and
worst deferred age.

Receiver metrics add applied FPS versus presented FPS, BC7 packet-arrival
interval, apply time, upload time, present submission time, present interval,
presented frame count and frames coalesced before presentation. New JSON fields
are optional so an updated Sender remains compatible with older Receivers.

## Validation invariants

- A deferred tile must remain different from the Receiver baseline until sent.
- Budget reduction must not permit unbounded tile age.
- Invalid delta checksums must not mutate live Receiver state.
- More than one BC7 packet must never be intentionally queued by the Sender.
- Receiver presentation may coalesce complete states but may not present a
  partially parsed packet.
