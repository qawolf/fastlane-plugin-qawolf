//
//  QWAudioRingBuffer.c
//  instrumentation
//
//  See QWAudioRingBuffer.h. Classic SPSC lock-free ring buffer: writeIndex is only ever
//  written by the producer and only ever read by the consumer (and vice versa for readIndex),
//  so acquire/release on those two atomics is sufficient -- no CAS loop needed since there's
//  exactly one writer and one reader for each.
//

#include "QWAudioRingBuffer.h"
#include <stdlib.h>
#include <string.h>

static size_t nextPowerOfTwo(size_t value) {
    size_t power = 1;
    while (power < value) {
        power <<= 1;
    }
    return power;
}

bool QWAudioRingBufferInit(QWAudioRingBuffer *rb, size_t minCapacityBytes) {
    if (rb == NULL || minCapacityBytes == 0) return false;
    size_t capacity = nextPowerOfTwo(minCapacityBytes);
    uint8_t *buf = (uint8_t *)malloc(capacity);
    if (buf == NULL) return false;
    rb->buffer = buf;
    rb->capacity = capacity;
    rb->mask = capacity - 1;
    atomic_store_explicit(&rb->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->readIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->resetRequested, false, memory_order_relaxed);
    return true;
}

void QWAudioRingBufferFree(QWAudioRingBuffer *rb) {
    if (rb == NULL) return;
    free(rb->buffer);
    rb->buffer = NULL;
    rb->capacity = 0;
    rb->mask = 0;
}

void QWAudioRingBufferClear(QWAudioRingBuffer *rb) {
    if (rb == NULL) return;
    atomic_store_explicit(&rb->resetRequested, true, memory_order_release);
}

// Applies a pending reset request in place, if any. Only ever called from the realtime reader
// (readIndex is the reader's alone to write), at the top of Read/ReadAll before checking
// availability.
static void applyPendingReset(QWAudioRingBuffer *rb) {
    if (!atomic_load_explicit(&rb->resetRequested, memory_order_acquire)) return;
    size_t w = atomic_load_explicit(&rb->writeIndex, memory_order_acquire);
    atomic_store_explicit(&rb->readIndex, w, memory_order_relaxed);
    atomic_store_explicit(&rb->resetRequested, false, memory_order_release);
}

size_t QWAudioRingBufferAvailableToRead(const QWAudioRingBuffer *rb) {
    if (rb == NULL) return 0;
    size_t w = atomic_load_explicit(&rb->writeIndex, memory_order_acquire);
    size_t r = atomic_load_explicit(&rb->readIndex, memory_order_acquire);
    return w - r; // unsigned wraparound-safe as long as capacity is a power of two and w-r never exceeds capacity
}

size_t QWAudioRingBufferWrite(QWAudioRingBuffer *rb, const uint8_t *data, size_t bytes) {
    if (rb == NULL || rb->buffer == NULL || data == NULL || bytes == 0) return 0;

    size_t w = atomic_load_explicit(&rb->writeIndex, memory_order_relaxed);
    size_t r = atomic_load_explicit(&rb->readIndex, memory_order_acquire);
    size_t used = w - r;
    size_t free_ = rb->capacity - used;
    size_t toWrite = bytes < free_ ? bytes : free_;
    if (toWrite == 0) return 0;

    size_t writePos = w & rb->mask;
    size_t firstChunk = rb->capacity - writePos;
    if (firstChunk >= toWrite) {
        memcpy(rb->buffer + writePos, data, toWrite);
    } else {
        memcpy(rb->buffer + writePos, data, firstChunk);
        memcpy(rb->buffer, data + firstChunk, toWrite - firstChunk);
    }

    atomic_store_explicit(&rb->writeIndex, w + toWrite, memory_order_release);
    return toWrite;
}

// Internal: performs the actual copy for a buffer already known to have enough data. Does not
// itself re-check availability (callers that need the check do it separately so ReadAll can
// check every channel before committing any of them).
static void readAssumingAvailable(QWAudioRingBuffer *rb, uint8_t *dest, size_t bytes) {
    size_t r = atomic_load_explicit(&rb->readIndex, memory_order_relaxed);
    size_t readPos = r & rb->mask;
    size_t firstChunk = rb->capacity - readPos;
    if (firstChunk >= bytes) {
        memcpy(dest, rb->buffer + readPos, bytes);
    } else {
        memcpy(dest, rb->buffer + readPos, firstChunk);
        memcpy(dest + firstChunk, rb->buffer, bytes - firstChunk);
    }
    atomic_store_explicit(&rb->readIndex, r + bytes, memory_order_release);
}

bool QWAudioRingBufferRead(QWAudioRingBuffer *rb, uint8_t *dest, size_t bytes) {
    if (rb == NULL || rb->buffer == NULL || dest == NULL || bytes == 0) return false;
    applyPendingReset(rb);
    if (QWAudioRingBufferAvailableToRead(rb) < bytes) return false; // underrun — leave dest untouched
    readAssumingAvailable(rb, dest, bytes);
    return true;
}

bool QWAudioRingBufferReadAll(QWAudioRingBuffer *const *rbs, uint8_t *const *dests,
                               const size_t *bytes, int count) {
    if (rbs == NULL || dests == NULL || bytes == NULL || count <= 0) return false;

    for (int i = 0; i < count; i++) {
        if (rbs[i] == NULL || rbs[i]->buffer == NULL || dests[i] == NULL || bytes[i] == 0) return false;
        applyPendingReset(rbs[i]);
    }
    // All-or-nothing: verify every channel has enough data before committing any read, so a
    // partial underrun on one channel can never desync it from the others.
    for (int i = 0; i < count; i++) {
        if (QWAudioRingBufferAvailableToRead(rbs[i]) < bytes[i]) return false;
    }
    for (int i = 0; i < count; i++) {
        readAssumingAvailable(rbs[i], dests[i], bytes[i]);
    }
    return true;
}
