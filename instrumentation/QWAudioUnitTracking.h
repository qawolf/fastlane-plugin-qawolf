//
//  QWAudioUnitTracking.h
//  instrumentation
//
//  Shared helpers for the AudioUnit-based mic-injection hooks -- audiounit/audiounit.m
//  (WebRTC/Agora's raw AudioUnit path) and audioengine/AVAudioEngineInputInjector.m (the
//  AVAudioEngine path). Each hook identifies AudioUnit instances at a different lifecycle
//  entry point (AudioUnitInitialize vs -[AVAudioEngine startAndReturnError:]) and owns its own
//  QWTrackedAudioUnitSet instance -- they track disjoint unit populations in practice
//  (AVAudioEngine's internal unit doesn't trigger the public AudioUnitInitialize call, which
//  is the whole reason the AVAudioEngine hook exists at all), so the sets are intentionally
//  kept separate rather than merged into one. What's shared is the *code*, not the tracked
//  state, so a future fix to the tracking mechanism (or FourCC rendering) only needs to be
//  made once instead of drifting across two copies.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

/// Human-readable rendering of a FourCC code (e.g. an AudioComponentDescription's type/
/// subType), non-printable bytes replaced with '.'.
NSString *QWFourCCToString(UInt32 code);

#define QW_TRACKED_AUDIO_UNIT_CAPACITY 16

/// Bounded set of AudioUnit pointers. Each slot is independently atomic (NULL = empty) and
/// never shifted -- only a single store per slot -- so QWTrackedAudioUnitSetContains can scan
/// the whole set with nothing but atomic loads: no lock, no torn reads, safe to call from a
/// realtime render thread. Add/remove (always non-realtime -- Initialize/Dispose, or engine
/// start) serialize against each other with an unfair lock; a realtime reader never touches
/// that lock.
typedef struct {
    _Atomic(AudioUnit) slots[QW_TRACKED_AUDIO_UNIT_CAPACITY];
    os_unfair_lock writeLock;
} QWTrackedAudioUnitSet;

#define QW_TRACKED_AUDIO_UNIT_SET_INIT { .writeLock = OS_UNFAIR_LOCK_INIT }

/// Realtime-safe: nothing but atomic loads.
BOOL QWTrackedAudioUnitSetContains(QWTrackedAudioUnitSet *set, AudioUnit unit);

/// Non-realtime. Returns YES if `unit` was newly added (callers that gate one-time setup on
/// first-time tracking should act only in that case); NO if already tracked (e.g. the
/// lifecycle entry point fired more than once for the same unit) or the set is full (logged
/// once via `logTag`, e.g. "audiounit" or "audioengine", to identify which hook is affected).
BOOL QWTrackedAudioUnitSetAddIfNew(QWTrackedAudioUnitSet *set, AudioUnit unit, const char *logTag);

/// Non-realtime. No-op if `unit` isn't tracked.
void QWTrackedAudioUnitSetRemove(QWTrackedAudioUnitSet *set, AudioUnit unit);

NS_ASSUME_NONNULL_END
