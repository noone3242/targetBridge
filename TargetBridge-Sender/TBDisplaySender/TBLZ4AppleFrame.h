#ifndef TBLZ4AppleFrame_h
#define TBLZ4AppleFrame_h

#include <stddef.h>
#include <stdint.h>

/// Size in bytes of the liblz4 compression state `TBLZ4EncodeAppleFrame` needs.
size_t TBLZ4AppleFrameStateSize(void);

/// Compresses `src` with liblz4 and frames it the way Apple's
/// `COMPRESSION_LZ4` does: a sequence of independent "bv41" blocks (or "bv4-"
/// raw blocks when a block does not compress), terminated by "bv4$". The
/// output decodes with `compression_decode_buffer(..., COMPRESSION_LZ4)`.
///
/// `state` must be `TBLZ4AppleFrameStateSize()` bytes, 8-byte aligned.
/// Returns the encoded size, or 0 when `dst` is too small or inputs are invalid.
/// The output never exceeds `TBLZ4AppleFrameBound(srcLength, blockSize)`.
size_t TBLZ4EncodeAppleFrame(uint8_t *dst, size_t dstCapacity,
                             const uint8_t *src, size_t srcLength,
                             void *state, int acceleration, size_t blockSize);

/// Worst-case output size: every block stored raw plus the end marker.
size_t TBLZ4AppleFrameBound(size_t srcLength, size_t blockSize);

/// Same as `TBLZ4EncodeAppleFrame` but without the "bv4$" end marker, so
/// independently encoded chunks can be concatenated into one frame by the
/// caller, which then appends the end marker with `TBLZ4WriteAppleFrameEnd`.
/// The output never exceeds `TBLZ4AppleBlocksBound(srcLength, blockSize)`.
size_t TBLZ4EncodeAppleBlocks(uint8_t *dst, size_t dstCapacity,
                              const uint8_t *src, size_t srcLength,
                              void *state, int acceleration, size_t blockSize);

/// Worst-case `TBLZ4EncodeAppleBlocks` output size.
size_t TBLZ4AppleBlocksBound(size_t srcLength, size_t blockSize);

/// Writes the 4-byte "bv4$" end marker. Returns 4, or 0 when `dstCapacity`
/// is too small.
size_t TBLZ4WriteAppleFrameEnd(uint8_t *dst, size_t dstCapacity);

#endif /* TBLZ4AppleFrame_h */
