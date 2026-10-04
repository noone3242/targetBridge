#include "TBLZ4AppleFrame.h"

#include <string.h>

#define LZ4_STATIC_LINKING_ONLY
#include "../ThirdParty/lz4/lz4.h"

enum {
    TBLZ4CompressedHeaderBytes = 12, // "bv41" + LE32 decoded + LE32 encoded
    TBLZ4RawHeaderBytes = 8,         // "bv4-" + LE32 length
    TBLZ4EndMarkerBytes = 4,         // "bv4$"
};

static void TBLZ4StoreLE32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

size_t TBLZ4AppleFrameStateSize(void) {
    return (size_t)LZ4_sizeofState();
}

size_t TBLZ4AppleBlocksBound(size_t srcLength, size_t blockSize) {
    if (blockSize == 0) {
        return 0;
    }
    size_t blocks = (srcLength + blockSize - 1) / blockSize;
    return srcLength + blocks * TBLZ4CompressedHeaderBytes;
}

size_t TBLZ4AppleFrameBound(size_t srcLength, size_t blockSize) {
    if (blockSize == 0) {
        return 0;
    }
    return TBLZ4AppleBlocksBound(srcLength, blockSize) + TBLZ4EndMarkerBytes;
}

size_t TBLZ4WriteAppleFrameEnd(uint8_t *dst, size_t dstCapacity) {
    if (!dst || dstCapacity < TBLZ4EndMarkerBytes) {
        return 0;
    }
    memcpy(dst, "bv4$", 4);
    return TBLZ4EndMarkerBytes;
}

size_t TBLZ4EncodeAppleBlocks(uint8_t *dst, size_t dstCapacity,
                              const uint8_t *src, size_t srcLength,
                              void *state, int acceleration, size_t blockSize) {
    if (!dst || !src || !state || srcLength == 0 || blockSize == 0 ||
        blockSize > (size_t)LZ4_MAX_INPUT_SIZE) {
        return 0;
    }
    size_t out = 0;
    for (size_t offset = 0; offset < srcLength; offset += blockSize) {
        size_t length = srcLength - offset < blockSize ? srcLength - offset : blockSize;
        if (dstCapacity - out < TBLZ4CompressedHeaderBytes) {
            return 0;
        }
        // Cap the output below the input so incompressible blocks fail fast
        // and are stored raw instead, as Apple's encoder does.
        size_t room = dstCapacity - out - TBLZ4CompressedHeaderBytes;
        int capacity = (int)(room < length - 1 ? room : length - 1);
        int encoded = 0;
        if (capacity > 0) {
            // The first block fully initializes the state; later blocks only
            // need the cheaper reset.
            encoded = offset == 0
                ? LZ4_compress_fast_extState(state, (const char *)src + offset,
                                             (char *)dst + out + TBLZ4CompressedHeaderBytes,
                                             (int)length, capacity, acceleration)
                : LZ4_compress_fast_extState_fastReset(state, (const char *)src + offset,
                                                       (char *)dst + out + TBLZ4CompressedHeaderBytes,
                                                       (int)length, capacity, acceleration);
        }
        if (encoded > 0) {
            memcpy(dst + out, "bv41", 4);
            TBLZ4StoreLE32(dst + out + 4, (uint32_t)length);
            TBLZ4StoreLE32(dst + out + 8, (uint32_t)encoded);
            out += TBLZ4CompressedHeaderBytes + (size_t)encoded;
        } else {
            if (dstCapacity - out < TBLZ4RawHeaderBytes + length) {
                return 0;
            }
            memcpy(dst + out, "bv4-", 4);
            TBLZ4StoreLE32(dst + out + 4, (uint32_t)length);
            memcpy(dst + out + TBLZ4RawHeaderBytes, src + offset, length);
            out += TBLZ4RawHeaderBytes + length;
        }
    }
    return out;
}

size_t TBLZ4EncodeAppleFrame(uint8_t *dst, size_t dstCapacity,
                             const uint8_t *src, size_t srcLength,
                             void *state, int acceleration, size_t blockSize) {
    size_t out = TBLZ4EncodeAppleBlocks(dst, dstCapacity, src, srcLength,
                                        state, acceleration, blockSize);
    if (out == 0) {
        return 0;
    }
    size_t end = TBLZ4WriteAppleFrameEnd(dst + out, dstCapacity - out);
    return end == 0 ? 0 : out + end;
}
