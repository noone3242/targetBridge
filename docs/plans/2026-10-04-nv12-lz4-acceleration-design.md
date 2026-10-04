# Raw NV12 LZ4 Acceleration Design

Date: 2026-10-04

## 1. Problem

The 5K raw NV12 tile-run path (format 4) runs detect → copy → LZ4 → send
serially on the Sender for every frame. Baseline measurements at `7c03537`
under heavy load (p95): detect 2.84 ms, copy 2.26 ms, LZ4 7.11 ms,
send 1.15 ms, about 13.4 ms in total. That leaves almost no headroom inside a
16.7 ms frame at 60 Hz, and LZ4 is the single largest cost.

## 2. Goals and constraints

- Cut Sender CPU time per frame, with LZ4 as the main target.
- TargetBridge is a display, so it must stay light on CPU. Prefer doing less
  work over spreading the same work across more cores.
- Latency must be deterministic. No offloading to efficiency cores through
  low QoS: macOS cannot pin threads, and a single E-core LZ4 pass would take
  15–20 ms.
- Always compress. Sending raw NV12 needs 4–10 Gbit/s at 60 Hz, which may
  trip traffic anomaly detection on managed machines.
- At most two performance cores for the encode.
- No Receiver change: it keeps decoding with Apple `COMPRESSION_LZ4`.

## 3. Options considered

| Option | Result | Decision |
|---|---|---|
| Hardware lossless compression | Apple Silicon exposes none; `compression.h` is software only and the media engines are lossy | Rejected |
| GPU gather of dirty tiles into a shared buffer | Saves only 0.1–0.2 ms CPU over a CPU zero-copy writer but adds 1–4 ms of wall time for the GPU round trip | Rejected |
| CPU zero-copy packet writer | 15–32% less CPU, byte-identical packets | Done (stage 1) |
| liblz4 with a high acceleration level | About 35% less encode CPU, about 17% more bytes, faster decode | Done (stage 2) |
| Adaptive "send uncompressed" | Conflicts with "always compress" | Rejected |
| Split LZ4 across 2 P-cores | Same total CPU, about half the wall time | Done (stage 3) |

## 4. Stage 1: zero-copy packet writer (landed in `6faa0b1`)

`TBNV12TileRunPacketWriter` allocates and prefaults its buffers once per
resolution:
- a raw staging area;
- two packet slots (about 66 MB resident at 5K);
- a reusable LZ4 scratch buffer.

Dirty tiles are copied with `memcpy` into the staging area. The packet header,
run table and LZ4 output are written in place into a free slot, which is
handed to `NWConnection` through `Data(bytesNoCopy:deallocator: .custom)`. A
slot is released only when the last reference to that `Data` goes away.

This removes:
- the `Data` growth reallocations and page faults;
- zero-filling the output buffer;
- two copies (`payload.append` and `makePacket`).

When no slot is free, or the input is invalid, the writer returns nil and the
old path builds the packet. `TB_NV12_ZERO_COPY=0` forces the old path.

## 5. Stage 2: liblz4 (landed in `6faa0b1`)

An Apple `COMPRESSION_LZ4` stream is a sequence of independent blocks:
- `bv41`, LE32 decoded size, LE32 encoded size, then the LZ4 block; or
- `bv4-`, LE32 size, then stored bytes;

followed by a `bv4$` end marker. The Sender encodes 1 MiB blocks with
vendored liblz4 1.10.0 (`ThirdParty/lz4`, BSD-2, licence in
`ThirdPartyNotices`) and wraps them in these headers itself (`TBLZ4AppleFrame.c`).
The Receiver decodes the result unchanged.

Why 1 MiB blocks:
- 64 KiB blocks decode about 30% slower.
- A single 15 MB block depends on older `libcompression` coping with huge
  blocks.
- 1 MiB is within 3% of the single-block speed.

Defaults and switches:
- Acceleration 32 by default. `TB_NV12_LIBLZ4_ACCELERATION=<n>` changes it.
- `TB_NV12_LIBLZ4=0` falls back to the Apple encoder.

Measured on a 15.48 MB (70% dirty) frame, CPU for packing plus compression:

| Path | p50 / p95 |
|---|---|
| Old path, Apple LZ4 | 10.59 / 11.89 ms |
| Zero-copy writer, liblz4 | 4.70 / 5.15 ms |

The ratio rises from 18.7% to 21.7% of raw, and Receiver decode gets faster.
On a real Intel macOS 14 Receiver, 80 seconds of window dragging produced no
decode failures and no keyframe requests.

## 6. Stage 3: parallel liblz4 on two P-cores (this branch)

### Design

Because blocks are independent and may have different sizes, a frame can be
encoded in pieces:
1. Cut the source into N equal chunks.
2. Encode each chunk into its own run of blocks, all chunks at the same time.
3. Concatenate the runs and append a single `bv4$`.

The result is still one valid frame, so neither the wire format nor the
Receiver changes. The chunk boundary adds at most one extra block boundary;
its effect on the ratio is negligible.

### Implementation

- `TBLZ4AppleFrame.{h,c}` adds:
  - `TBLZ4EncodeAppleBlocks`, which encodes without the end marker;
  - `TBLZ4AppleBlocksBound`;
  - `TBLZ4WriteAppleFrameEnd`.

  `TBLZ4EncodeAppleFrame` is now built from them and still produces the same
  bytes as before.
- `TBNV12ParallelLZ4Encoder` holds one liblz4 state per thread and N−1
  prefaulted side buffers.
  - Chunk 0 is written directly into the destination. The other chunks go to
    side buffers and are copied in after the join, so the extra copy only
    touches compressed bytes.
  - `DispatchQueue.concurrentPerform` runs one chunk on the calling thread.
    The helper thread inherits the pipeline queue's QoS, so both stay on
    P-cores.
- The serial path is used for:
  - inputs under 1 MiB;
  - a thread count of 1;
  - the Apple encoder.

  It produces exactly the same bytes as the single-threaded encoder.
- Thread count:
  - 2 when `hw.perflevel0.physicalcpu` ≥ 4, otherwise 1;
  - `TB_NV12_LZ4_THREADS=<n>` overrides it (1 disables the split);
  - never more than the number of P-cores.
- Used by every raw NV12 packet that is compressed: full (format 2), region
  (format 3), tile runs (format 4) and copy rects (format 5).
- The metrics field `nv12LZ4Encoder` reports the thread count, for example
  `liblz4-a32-t2`.

### Cost

Total CPU stays the same. LZ4 wall time drops to about half on large frames,
using a second P-core only for the duration of the encode.

## 7. Tests

- `TBNV12ParallelLZ4EncoderTests`:
  - round trip through the Apple decoder;
  - N=1 output is byte-identical to the serial encoder;
  - small inputs take the serial path;
  - the thread-count policy;
  - the diagnostic name.
- Earlier stages: the writer produces byte-identical packets to the old path
  and refuses to overwrite in-flight slots.
- Real-device check still needed: LZ4 p95 with `-t2` against
  `TB_NV12_LZ4_THREADS=1` on the same content.
