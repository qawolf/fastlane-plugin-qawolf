//
//  QWAudioUnitTracking.m
//  instrumentation
//
//  See QWAudioUnitTracking.h for context.
//

#import "QWAudioUnitTracking.h"

NSString *QWFourCCToString(UInt32 code) {
    char bytes[5] = {
        (char)((code >> 24) & 0xFF),
        (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF),
        (char)(code & 0xFF),
        0
    };
    for (int i = 0; i < 4; i++) {
        if (bytes[i] < 32 || bytes[i] > 126) bytes[i] = '.';
    }
    return [NSString stringWithUTF8String:bytes];
}

BOOL QWTrackedAudioUnitSetContains(QWTrackedAudioUnitSet *set, AudioUnit unit) {
    for (int i = 0; i < QW_TRACKED_AUDIO_UNIT_CAPACITY; i++) {
        if (atomic_load_explicit(&set->slots[i], memory_order_acquire) == unit) return YES;
    }
    return NO;
}

BOOL QWTrackedAudioUnitSetAddIfNew(QWTrackedAudioUnitSet *set, AudioUnit unit, const char *logTag) {
    os_unfair_lock_lock(&set->writeLock);
    int freeSlot = -1;
    for (int i = 0; i < QW_TRACKED_AUDIO_UNIT_CAPACITY; i++) {
        AudioUnit existing = atomic_load_explicit(&set->slots[i], memory_order_relaxed);
        if (existing == unit) {
            // already tracked (e.g. the lifecycle entry point fired more than once for the
            // same unit)
            os_unfair_lock_unlock(&set->writeLock);
            return NO;
        }
        if (existing == NULL && freeSlot < 0) freeSlot = i;
    }
    BOOL isNew = NO;
    if (freeSlot >= 0) {
        atomic_store_explicit(&set->slots[freeSlot], unit, memory_order_release);
        isNew = YES;
    } else {
        NSLog(@"QAWolf:%s: tracked-unit table full (%d) -- not tracking unit=%p",
              logTag, QW_TRACKED_AUDIO_UNIT_CAPACITY, (void *)unit);
    }
    os_unfair_lock_unlock(&set->writeLock);
    return isNew;
}

void QWTrackedAudioUnitSetRemove(QWTrackedAudioUnitSet *set, AudioUnit unit) {
    os_unfair_lock_lock(&set->writeLock);
    for (int i = 0; i < QW_TRACKED_AUDIO_UNIT_CAPACITY; i++) {
        if (atomic_load_explicit(&set->slots[i], memory_order_relaxed) == unit) {
            atomic_store_explicit(&set->slots[i], NULL, memory_order_release);
            break;
        }
    }
    os_unfair_lock_unlock(&set->writeLock);
}
