# Raw NV12 Copy-Rect (Format 5) Design

Date: 2026-10-04

## 1. Problem

Dragging a window or scrolling a page changes almost every tile under the
moving content, even though the pixels have only moved. Format 4 then resends
most of the screen at 5K (often more than 70% of tiles), costing:
- 10–15 MB of LZ4 input per frame;
- 3–4 Gbit/s on the link.

These frames dominate both Sender CPU and bandwidth during normal desktop use.

The idea, as in VNC/RDP `CopyRect`: when dirty tiles equal the previous frame
shifted by one vector, send the vector and the tile list instead of the
pixels. The Receiver moves the pixels it already has.

## 2. Goals and constraints

- Lossless. A copied tile must be bit-exact; anything else is sent fresh.
- The search must be cheaper than the LZ4 work it saves, and must not run
  continuously on content it cannot help (video, animation).
- Deterministic latency: no work on efficiency cores, no extra frames of
  queueing.
- No capability negotiation. The Receiver is assumed to be the current
  version; `TB_NV12_COPY_RECT=0` on the Sender is the only switch.
- Every Receiver error recovers through the existing keyframe request.

## 3. Correctness invariant

The Sender's tile detector keeps a committed baseline, which is the frame the
Receiver is showing. Format 4 already relies on this.

A copy is used only after the GPU has compared every pixel (Y and UV) of the
tile with the baseline shifted by the vector. So for every copied tile:

    current(x, y) == baseline(x - dx, y - dy)

Fresh tiles carry the current pixels, and clean tiles already equal the
baseline. After the Receiver applies the packet, its frame equals the current
frame, which is exactly what the Sender commits as the new baseline. The
search is only a hint: a wrong guess costs time, never correctness.

## 4. Sender detection (`TBNV12TileDetector`)

The work runs on the GPU in two synchronous command buffers.

1. **Anchors.** Up to 64 dirty tiles, evenly spaced over the sorted dirty
   set. `nv12_anchor_texture` reads 64 luma samples on a staggered 8×8 grid
   inside each anchor tile. It keeps only anchors with at least 8
   sample-to-sample changes, because flat tiles match almost any offset.
2. **Search.** `nv12_shift_search` checks each anchor's 64 samples against
   the baseline at every candidate offset. There are 39,328 candidates, all
   even so that the half-resolution UV plane shifts exactly:
   - any offset in a ±192 px box (drags);
   - purely vertical offsets up to ±1440 px (scrolls);
   - purely horizontal offsets up to ±1024 px.

   Each anchor records up to 8 matching offsets.
3. **Vote.** An anchor that matches more than 8 offsets is repetitive
   content and gets no vote. Every other match is one vote. The winning
   offset needs at least 2 votes. Ties go to the previous frame's vector
   (scrolls keep their speed), then to the shorter vector.
4. **Verify.** `nv12_tile_shift_compare` compares every dirty tile exactly
   (Y and UV) against the shifted baseline. Tiles whose source would fall
   outside the frame do not match. The candidate is kept only if at least 16
   tiles match.

## 5. Packet selection

`makeRawNV12CopyRectPacket` runs before the format 4 choice. It needs:
- copy-rect enabled;
- the zero-copy writer;
- at least 32 dirty tiles.

It produces format 5 when:
- copied tiles × 4 ≥ dirty tiles (at least a quarter of the dirty area is
  copied);
- the remaining fresh tiles form at most 256 runs;
- the zero-copy writer has a free slot.

Otherwise the frame falls through to the existing choice: format 4 when under
75% of tiles are dirty and there are at most 256 runs, or else the bounding
region.

## 6. Search backoff (`TBNV12CopyRectBackoff`)

Video and animation make many tiles dirty without any shift, so each search
would be wasted.
- After 2 consecutive misses, the next 4 eligible frames skip the search.
- Each further miss doubles the skip, up to 8 frames.
- A hit resets the backoff.
- So does a frame with fewer than 32 dirty tiles, a gap of more than 100 ms
  between eligible frames (capture sends nothing while the screen is idle),
  a keyframe request or a resolution change.

That way a scroll that starts after the screen was quiet is searched at once.
A reject (too many fresh runs, or no writer slot) counts as a miss.

## 7. Wire format 5

The header is 40 bytes, big endian:

| Offset | Field |
|---|---|
| 0 | format = 5 |
| 1 | compression = 1 (LZ4) |
| 2..3 | tile size = 64 |
| 4 | width |
| 8 | height |
| 12 | fresh run count |
| 16 | raw length |
| 20 | compressed length |
| 24 | checksum (u64, 0 = none) |
| 32 | dx (s16) |
| 34 | dy (s16) |
| 36 | copy run count (≥ 1) |

The header is followed by:
1. Copy runs, 8 bytes each: tile_x, tile_y, tile_count_x, reserved 0.
2. Fresh runs, 16 bytes each, in the format 4 layout.
3. The LZ4 stream of the fresh tiles, in the format 4 layout. When there are
   no fresh runs, both lengths are 0 and there is no stream.

Semantics: a copied tile at (x, y) takes the previous frame's pixels at
(x − dx, y − dy). All copies read the previous frame as a snapshot, then the
fresh runs are written.

The parser (`tb_nv12_copy_rect_parse`) rejects:
- odd or zero vectors;
- runs that are out of row-major order or overlap;
- copy sources outside the frame;
- copy and fresh runs that overlap each other;
- lengths that do not match.

The Sender's test decoder (`TBNV12Compression.decodeCopyRectPacket`) enforces
the same rules.

## 8. Receiver

- **Shadow.** The Receiver keeps a CPU NV12 copy of the displayed frame, with
  a tight stride equal to the width. Keyframes, region frames and format 4
  frames write into it, so it always matches the screen.
- **Apply in place** (`tb_nv12_copy_rect_apply_copies`). The copies are
  applied with `memmove`, in an order chosen so that no source pixel is
  overwritten before it is read:
  - rows bottom-up when dy > 0, otherwise top-down;
  - within a row, right to left when dy == 0 and dx > 0.

  When dy ≠ 0 a source row is never a destination row in the same pass. When
  dy == 0, the row order inside each tile row makes `memmove` safe. Snapshot
  semantics therefore hold without a second full-frame buffer.
- **Fresh runs.** These are decoded with Apple LZ4, checked against the
  optional checksum, and written into the shadow.
- **Upload.** `tb_nv12_copy_rect_dirty_rects` builds one span per tile row
  (from the leftmost to the rightmost touched tile) and merges vertically
  adjacent rows with the same span. Each rectangle is uploaded from the
  shadow with `tb_disp_update_nv12_region`, then the frame is presented.
- **Errors.** Any failure requests a keyframe with a specific reason:
  `copy-rect-base`, `-format`, `-allocation`, `-decode`, `-checksum`,
  `-upload` or `-present`. The Sender then resets the baseline, the last
  vector and the backoff.

## 9. Metrics

Sender:

| Metric | Meaning |
|---|---|
| `nv12CopyRectFrames` | Format 5 packets sent |
| `nv12CopyRectTiles` | Tiles sent as copies |
| `nv12CopyRectRejects` | Vector found but packet not built |
| `nv12CopyRectSkippedSearches` | Searches skipped by the backoff |
| `nv12CopyRectSearchP50Ms`, `nv12CopyRectSearchP95Ms` | Search plus verify time |
| `nv12CopyRectLastVector` | Last vector used |

Receiver:
- `rawCopyRectFrames` and `rawCopiedTiles`;
- the existing shadow commit timing;
- keyframe reasons prefixed with `copy-rect-`.

## 10. Cost

- **Sender:** two GPU round trips per searched frame, which are synchronous
  on the pipeline queue. The estimate is 1–3 ms at 5K; it has not been
  measured on the device yet. On a hit, this replaces the LZ4 and copy work
  for most of the frame (several ms). On video, the backoff limits the waste
  to about 1 search in 5 eligible frames, falling to 1 in 9.
- **Receiver:**
  - a shadow write for every raw frame (a full 22 MB copy on keyframes);
  - a `memmove` of the copied area;
  - uploads that cover the copied area as well as the fresh tiles.

  This adds bandwidth but no decode, and is much cheaper than decoding
  the same area.
- **Link:** a pure scroll frame is about 0.1–1 MB instead of 10–15 MB.

## 11. Tests

Sender (`TBNV12CopyRectTests`):
- the detector finds drag and scroll vectors and rejects unrelated or flat
  content;
- verification is exact for any vector;
- the search offsets are even, unique and cover the drag box and scroll
  ranges;
- the writer round-trips through the test decoder, including copy-only
  frames, and rejects invalid copies;
- the decoder rejects malformed packets;
- the backoff schedule.

Receiver (`tests/test_net_parser.c`):
- parse accept and reject cases;
- in-place copies checked against a snapshot reference for scrolls up and
  down, a sub-tile shift, a diagonal drag over its own old position, and
  same-row shifts left and right;
- the dirty-rect merge.

Still to do: an end-to-end check on real hardware with window drag and scroll,
plus search-time numbers at 5K.

## 12. Limitations

- One vector per frame. Two windows moving in different directions get only
  the stronger vector; the rest is sent fresh.
- Odd-pixel shifts cannot be copied (the UV plane is half resolution) and
  fall back to format 4.
- Content that is scaled or changes while it moves (zoom, fade, smooth
  scrolling with re-rasterised text) fails verification and is sent fresh.
- Older Receivers do not understand format 5 and would loop on keyframe
  requests. Run them with `TB_NV12_COPY_RECT=0`.
