# 5K transport version and metrics history

This document records the measured TargetBridge 5K transport experiments.
Tagged commits are frozen checkpoints that can be restored directly. Untagged
commits are intermediate experiments or branch history.

The measurements below were collected on the MacBook Sender to Intel iMac
Receiver path. Workload, drag area, and sampling duration were not identical
between experiments, so these numbers are historical facts rather than a
strict apples-to-apples benchmark.

For JSONL summaries, a high-load sample means:

```text
networkGbps >= 0.3
```

## Version graph

```text
fba7473  BC7 stable baseline
└─ tag: bc7-5k-stable-2026-09-26
   └─ 54a1836  GPU tile planner
      └─ tag: bc7-5k-gpu-planner-stable-2026-09-26
         ├─ adaptive branch
         │  └─ 4b0b12a implementation → ab38756 experiment report
         └─ BC7 compression branch
            └─ 0bef248 low-latency scheduling
               └─ e8f439b LZFSE
                  └─ 52b4ece BC7 LZ4
                     └─ tag: bc7-5k-lz4-low-bandwidth-checkpoint-2026-09-27
                     └─ Raw NV12 branch
                        └─ 0dcec16 full NV12
                           └─ a153d50 bounding-region delta
                              └─ f492b1e recoverable region
                                 └─ b3f4161 pipeline metrics
                                    └─ b904306 checksum disabled
                                       └─ tag: nv12-5k-high-fps-high-bandwidth-checkpoint-2026-09-27
                                       └─ 7c03537 GPU-detected NV12 tile runs
```

## Frozen checkpoints

| Tag | Commit | Transport | Measured state |
|---|---|---|---|
| `bc7-5k-stable-2026-09-26` | `fba7473d2b80` | GPU BC7 encode, CPU tile planning, changed-tile runs | Sender about 45.6 FPS average and 58 FPS peak; Receiver repeatedly reached 54–57 FPS; Sender/Receiver peak bandwidth 2.165/2.126 Gbit/s |
| `bc7-5k-gpu-planner-stable-2026-09-26` | `54a1836c81e5` | GPU BC7 encode and GPU tile analysis | Sender 45.33 Hz; Receiver 47.31 FPS average and 56.77 FPS peak; Sender average/peak bandwidth 1.841/3.228 Gbit/s; Receiver peak 2.928 Gbit/s; no drops or protocol/render errors |
| `bc7-5k-lz4-low-bandwidth-checkpoint-2026-09-27` | `52b4ece57f1a` | Changed BC7 tile runs in one Raw-BC7 LZ4 stream | Sender 53.90 Hz; Receiver 36.37 FPS; average/peak bandwidth 0.417/0.518 Gbit/s; Sender LZ4 p95 about 3.83 ms; Receiver decompression p95 about 3.15 ms; visible stutter remained |
| `nv12-5k-high-fps-high-bandwidth-checkpoint-2026-09-27` | `b90430696861` | Raw NV12 bounding-region LZ4, partial texture upload, checksum disabled | High-load average Sender/Receiver 51.72/51.79 FPS; average/peak bandwidth 1.133/3.074 Gbit/s; a consistent drag interval reached about 55–58 FPS; no invalid frames, render failures, or keyframe requests |

## Experiment table

| Commit | Version | Tag/checkpoint | High-load samples | Average bandwidth | Peak bandwidth | Measured performance |
|---|---|---|---:|---:|---:|---|
| `fba7473d2b80` | BC7 stable baseline | `bc7-5k-stable-2026-09-26` | Historical experiment | Not retained in the same aggregation format | Sender 2.165 / Receiver 2.126 Gbit/s | Sender about 45.6 FPS; Receiver repeatedly 54–57 FPS |
| `54a1836c81e5` | BC7 GPU planner | `bc7-5k-gpu-planner-stable-2026-09-26` | 6 | 1.841 Gbit/s | Sender 3.228 / Receiver 2.928 Gbit/s | Sender 45.33 Hz; Receiver 47.31 FPS |
| `4b0b12af7f3c` | Adaptive 5K90 MVP | No tag | 52 one-second windows | 0.541 Gbit/s | Not retained | Sender 34.77 Hz; Receiver varied from about 2–60 FPS; visible tearing and jumping; cumulative dropped count peaked at 376 |
| `0bef248` | BC7 low-latency scheduling | No tag | 38-second drag run | Not retained | Not retained | Sender 54.87 Hz; Receiver 54.15 FPS; Receiver cadence p95 about 29–31 ms |
| `e8f439b` | BC7 byte-plane LZFSE | No tag | Hardware run | Absolute bandwidth not retained; wire/raw about 17% | Not retained | Receiver about 41 FPS; Sender compression p50/p95 18.68/40.62 ms |
| `52b4ece57f1a` | BC7 LZ4 | `bc7-5k-lz4-low-bandwidth-checkpoint-2026-09-27` | 10 | 0.417 Gbit/s | 0.518 Gbit/s | Sender 53.90 Hz; Receiver 36.37 FPS; compressed block ratio about 15.7% |
| `0dcec16d243a` | Full-frame NV12 LZ4 | No tag | 18 | 0.498 Gbit/s | 0.577 Gbit/s | About 10–15 FPS; every frame copied and compressed 22.1 MB |
| `a153d503bd0f` | NV12 bounding-region delta | No tag | 41 | 0.550 Gbit/s | 0.952 Gbit/s | Sender 41.69 Hz; Receiver stage metrics were not complete |
| `f492b1e82950` | Recoverable NV12 region | No tag | 37 | 0.431 Gbit/s | 0.515 Gbit/s | Sender 26.98 Hz; Receiver 29.11 FPS; Sender LZ4 p95 7.65 ms; Receiver apply p95 23.23 ms |
| `b3f416150a39` | NV12 pipeline breakdown | No tag | No valid paired deployment | Not available | Not available | Instrumentation, reusable decode scratch, and shadow-state changes; Receiver was not deployed at the same commit |
| `b90430696861` | NV12 checksum disabled | `nv12-5k-high-fps-high-bandwidth-checkpoint-2026-09-27` | 80 | 1.133 Gbit/s | 3.074 Gbit/s | Sender 51.72 Hz; Receiver 51.79 FPS; selected intervals reached 55–58 FPS |
| `7c03537705c4` | GPU-detected NV12 64×64 tile runs | No tag | 48 high-load windows | 0.812 Gbit/s | 1.780 Gbit/s | Sender 55.04 Hz; Receiver 53.33 FPS; tile detection p95 snapshot average 2.84 ms; no protocol or render errors |

## Stage measurements

### `54a1836` BC7 GPU planner

```text
GPU encode average:       5.80 ms
GPU tile plan average:    0.492 ms
packet average:           1.435 ms
send completion average:  6.095 ms
pending:                  <= 1
dropped/send errors:      0
Receiver invalid/render:  0
```

### `52b4ece` BC7 LZ4

```text
Sender LZ4 p50/p95:       2.62 / 3.83 ms
Receiver LZ4 p95:         3.15 ms
compressed/raw ratio:     15.7%
Receiver packet p95:      31.7 ms
Sender sync path p95:     18.65 ms
```

### `f492b1e` recoverable NV12 region

```text
region pixels p50/p95:    8.7M / 11.8M
overfetch p50/p95:        1.00x / 1.27x
Sender copy p50/p95:      1.00 / 1.34 ms
Sender LZ4 p50/p95:       4.80 / 8.60 ms
queue age p95:            48.7 ms
Receiver decompress p95:  4.87 ms
Receiver apply p95:       25.1 ms
upload + present p95:     about 3.8–4.2 ms
Receiver cadence p95:     about 82 ms
```

### `b904306` checksum-disabled NV12

Across all 80 saved high-load samples:

```text
Sender capture/sent:      51.69 / 51.72 Hz
Receiver present:         51.79 FPS
network average/peak:     1.133 / 3.074 Gbit/s
send p95 snapshot avg:    3.96 ms
LZ4 p95 snapshot avg:     13.02 ms
Receiver apply p95 avg:   7.99 ms
checksum:                 0 ms
protocol/render errors:   0
```

A more consistent 28-window dragging interval measured:

```text
Sender capture/sent:      55.47 / 55.50 Hz
Receiver present:         55.74 FPS
network average/peak:     0.784 / 1.061 Gbit/s
Receiver apply p95:       7.45 ms
Receiver decompress p95:  4.07 ms
upload + present p95:     3.69 ms
```

Later, more widely separated damage produced bounding-region overfetch p95
snapshots from 1.45x to 17.16x and Sender LZ4 p95 snapshots up to about 26 ms.
This explains why the same commit varies from about 55–58 FPS in localized
motion to about 51–52 FPS over the broader high-load sample set.

### `7c03537` GPU-detected NV12 tile runs

Extended run after deploying format 4. The sample set contains 48 windows with
`networkGbps >= 0.3`.

```text
Sender capture/sent:          55.56 / 55.04 Hz
Receiver present:             53.33 FPS
network average/peak:         0.812 / 1.780 Gbit/s
GPU tile detection p95 avg:   2.84 ms
run count p95 avg/max:        76.60 / 88
Sender run copy p95 avg:      2.26 ms
Sender LZ4 p95 avg:           7.11 ms
Sender send p95 avg:          1.15 ms
Receiver decompress p95 avg:  3.25 ms
Receiver upload p95 avg:      2.18 ms
Receiver apply p95 avg:       5.31 ms
invalid/render/key requests:  0 / 0 / 0
```

Compared with the broader `b904306` high-load sample set, observed average
bandwidth decreased from 1.133 to 0.812 Gbit/s (28.3%), while Sender/Receiver
rates changed from 51.72/51.79 to 55.04/53.33 FPS. The workloads and sample
counts were not identical, so this is an initial hardware result rather than a
controlled benchmark.

## Branch heads

| Branch | Head |
|---|---|
| `2026-09-26_intel-bc7-debug` | `52b4ece57f1a` |
| `2026-09-26_adaptive-5k-90hz` | `ab38756` |
| `2026-09-27_raw-nv12-low-latency` | `729d9f4` after tile runs and stable local signing |

The active Raw NV12 branch may advance beyond `b904306`; use the checkpoint
tag rather than the moving branch name when reproducing its measured behavior.

## Unfinished Raw NV12 optimization work

The items in this section are implementation status and measurement
requirements, not measured performance claims.

| Item | Status | Current cost addressed | Dependency / risk | Required validation |
|---|---|---:|---|---|
| GPU tile-run packing into a shared `MTLBuffer` | Implemented in `29c13be`; hardware load test pending | CPU run copy p95 averaged 2.26 ms in `7c03537` | Requires valid Screen Recording authorization after the signing migration | Byte-exact output, packing p50/p95, LZ4 p95, FPS and bandwidth under the same drag workload |
| Candidate-only GPU tile comparison | Not implemented | Full-frame exact tile detection p95 averaged 2.84 ms | SCK dirty rectangles must be accumulated across dropped frames; periodic full scans may still be required | Missed-damage mutation tests, candidate tile count and detection p95 |
| GPU run compaction | Not implemented | CPU reads tile flags and constructs horizontal run descriptors | Variable-length GPU output and synchronization | Run descriptors byte-exact against CPU planner; command count and wall time |
| Independent compression chunks | Blocked on codec choice | Sender LZ4 p95 averaged 7.11 ms; Receiver LZ4 p95 averaged 3.25 ms | Separate chunks reset compression history and may increase wire bytes | Compression wall time, total CPU time, chunk count, wire/raw ratio and malformed-chunk recovery |
| Multicore Sender compression | Not implemented | Single-stream CPU LZ4 compression | Requires independent chunk wire format | Same-frame byte-exact decode, p50/p95 wall time, per-core CPU and bandwidth |
| Multicore Receiver decompression | Not implemented | Single-stream CPU LZ4 decode | Requires independent chunks and atomic completion before texture mutation | Decode wall time, failed-chunk recovery and no partial texture commit |
| Alternative lossless tile codec | Undecided | LZ4 CPU cost and 22.2% average wire/raw ratio | Metal has no public LZ4/zstd hardware API; a custom GPU codec needs match finding and variable-output compaction | Cross-architecture decoder, bit-exact corpus, malformed data and throughput |
| Hardware HEVC path | Existing product path, not evaluated as a replacement for format 4 | Could replace tile LZ4 with media-engine video coding | Lossy video semantics, frame dependencies and different latency/recovery behavior | Identical 5K drag/video workload, encode/decode hardware status, quality and end-to-end latency |
| BC7 hardware texture path | Preserved at checkpoint `52b4ece` | 8 bpp texture blocks and GPU-native sampling | Lossy texture compression; historical Receiver cadence was poor | Retest `52b4ece` Sender against the latest Receiver before attributing 36.37 FPS to the codec |
| Batched Receiver NV12 scatter | Not implemented | Multiple `SDL_UpdateNVTexture` calls; upload p95 averaged 2.18 ms | Requires a Metal NV12 renderer or staging-buffer scatter path instead of SDL-owned texture updates | Run-count scaling, upload p50/p95 and one-present-per-frame invariant |
| Temporal XOR before lossless compression | Not implemented | Average packed raw input was 8.51 MB/frame | Requires an exact synchronized NV12 baseline and full-keyframe recovery after any loss | Byte-exact recovery, dropped-frame mutation and compression-ratio distribution |
| Separate Y and UV compression | Not implemented | Different entropy in luma and chroma planes | Adds streams and metadata; benefit is content-dependent | Per-plane ratio and wall time on desktop, scrolling and video workloads |
| Adaptive tile size | Not implemented | 64×64 can over-send boundaries or create many runs | Smaller tiles increase descriptors/uploads; larger tiles increase overfetch | 32/64/128 tile A/B with unique changed bytes, run count, bandwidth and FPS |
| Tile budget / defer / worst-age governor | Not implemented for NV12 | Burst bandwidth and long LZ4 frames | Updates become delayed and require eventual-lossless convergence rules | Worst tile age, convergence time, bandwidth cap and visual behavior |
| Fixed-cadence Receiver present loop | Not implemented for NV12 | Packet-arrival jitter affects display cadence | Does not create missing source frames; display loop must present the latest complete texture only | Present interval p50/p95/p99 and duplicate-present count |
| Controlled version benchmark harness | Not implemented | Historical version samples used different drag workloads | Requires deterministic UI motion or a reproducible capture source | Same action duration and content for every tag, with raw JSONL artifacts retained |

### Compression-path decision still open

The next compression layer has materially different semantics:

```text
Lossless Raw NV12:
  GPU pack -> CPU multicore LZ4/other lossless codec

Lossy GPU texture:
  GPU BC7/BC1 encode -> GPU-native texture sampling

Lossy hardware video:
  VideoToolbox HEVC encode -> VideoToolbox decode

Custom lossless GPU:
  GPU tile pack -> custom Metal codec -> custom GPU/CPU decoder
```

The format 4 checkpoint remains lossless Raw NV12 with CPU LZ4. GPU packing is
independent of this decision and can feed any later compression path.
