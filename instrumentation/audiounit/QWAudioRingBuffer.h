//
//  QWAudioRingBuffer.h
//  instrumentation
//
//  Single-producer/single-consumer lock-free byte ring buffer. The producer (QWAudioUnitBridge,
//  fed from MockMediaSource's audio tap) runs on a non-realtime thread; the consumer
//  (audiounit.m's AudioUnitRender hook) runs on the realtime audio I/O thread. Neither side
//  ever blocks or allocates after QWAudioRingBufferInit.
//
//  "Clear" is deliberately NOT an immediate non-realtime write to readIndex: readIndex is
//  owned exclusively by the realtime reader (the SPSC invariant this whole structure depends
//  on), so QWAudioRingBufferClear only posts a request-flag that the reader consumes and acts
//  on itself, the next time it runs. That makes it realtime-safe to call from either side.
//

#ifndef QWAudioRingBuffer_h
#define QWAudioRingBuffer_h

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *buffer;
    size_t capacity;   // power-of-two, in bytes
    size_t mask;       // capacity - 1, for cheap index wrapping
    _Atomic size_t writeIndex;
    _Atomic size_t readIndex;
    _Atomic bool resetRequested;
} QWAudioRingBuffer;

// Allocates the backing buffer (rounded up to the next power of two >= minCapacityBytes).
// Call only from non-realtime setup code. Returns false on allocation failure.
bool QWAudioRingBufferInit(QWAudioRingBuffer *rb, size_t minCapacityBytes);

// Frees the backing buffer. Call only from non-realtime code, and only once no producer/
// consumer is still using the buffer (see QWAudioUnitBridge.m's generation-retirement scheme
// for how callers guarantee that without a lock).
void QWAudioRingBufferFree(QWAudioRingBuffer *rb);

// Requests that buffered audio be discarded. Safe to call from any thread, concurrently with
// the realtime reader — it only sets a flag; the reader applies it (and clears the flag) the
// next time QWAudioRingBufferRead/ReadAll runs, before doing anything else.
void QWAudioRingBufferClear(QWAudioRingBuffer *rb);

// Producer side (non-realtime thread). Never blocks. Returns the number of bytes actually
// written — fewer than requested if the buffer doesn't have room (oldest data is not
// overwritten; the excess is simply dropped, since a live broadcast wants gapless-but-current
// audio more than it wants a long buffered backlog).
size_t QWAudioRingBufferWrite(QWAudioRingBuffer *rb, const uint8_t *data, size_t bytes);

// Consumer side (realtime thread). Never blocks, never allocates. Only fills `dest` and
// returns true if at least `bytes` were available; otherwise returns false and leaves `dest`
// untouched, so the caller can fall back to passing through its own (real) audio unchanged.
bool QWAudioRingBufferRead(QWAudioRingBuffer *rb, uint8_t *dest, size_t bytes);

// All-or-nothing read across several ring buffers at once (one per destination channel, for
// a non-interleaved multi-channel format) — either every buffer has enough data and all are
// read together, or none are touched at all, so channels can never drift out of sync with
// each other from a partial per-channel underrun. Realtime-safe, same guarantees as
// QWAudioRingBufferRead.
bool QWAudioRingBufferReadAll(QWAudioRingBuffer *const *rbs, uint8_t *const *dests,
                               const size_t *bytes, int count);

// How many bytes are currently available to read. Safe to call from either side.
size_t QWAudioRingBufferAvailableToRead(const QWAudioRingBuffer *rb);

#ifdef __cplusplus
}
#endif

#endif /* QWAudioRingBuffer_h */
