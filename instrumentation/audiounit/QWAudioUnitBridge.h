//
//  QWAudioUnitBridge.h
//  instrumentation
//
//  Glue between MockMediaSource's existing injected-media audio pipeline and audiounit.m's
//  AudioUnitRender injection hook. Owns the format conversion (source PCM as delivered by the
//  audio tap -> whatever format the mic-capture Audio Unit actually wants) and the realtime-
//  safe ring buffer(s) that decouple the two.
//
//  This is what lets `ios.injectAudio()` reach a WebRTC broadcast with no new test-facing API:
//  MockMediaSource pushes converted samples in here whenever injected audio is playing
//  (regardless of whether any AVCaptureAudioDataOutput/AVAudioRecorder consumer is also
//  registered), and audiounit.m drains them into the mic-capture Audio Unit's render buffer.
//
//  Internally, one ring buffer is used per destination channel for non-interleaved multi-
//  channel formats (one for interleaved formats, which covers everything observed so far —
//  see TASK.md). All buffers for a given target format are allocated together as one
//  "generation"; reconfiguring the target format (e.g. on Audio Unit re-creation) swaps in a
//  new generation behind an atomic pointer rather than mutating shared state in place, so the
//  realtime reader never sees a half-updated or freed buffer.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface QWAudioUnitBridge : NSObject

+ (instancetype)sharedInstance;

/// Called by audiounit.m's AudioUnitInitialize hook (non-realtime thread) once a WebRTC
/// engine's mic-capture Audio Unit is identified and its negotiated stream format is known.
/// Safe to call more than once (e.g. across broadcast attempts / unit re-creation) — allocates
/// a new ring-buffer generation and atomically swaps it in if the format actually changed.
- (void)configureTargetFormat:(const AudioStreamBasicDescription *)format;

/// Called by MockMediaSource's audio tap process callback whenever new source PCM is
/// available from the currently injected media (independent of whether any
/// AVCaptureAudioDataOutput/AVAudioRecorder consumer is registered — this path always runs
/// while injected audio is playing). Converts to the configured target format and pushes the
/// result into the ring buffer(s) audiounit.m's render hook reads from. No-ops until
/// -configureTargetFormat: has been called at least once.
- (void)pushSourceBuffer:(AudioBufferList *)bufferList
             sourceFormat:(AudioStreamBasicDescription)sourceFormat
               frameCount:(UInt32)frameCount;

/// Requests that any buffered-but-unplayed audio be discarded. Realtime-safe to call
/// concurrently with the render hook (see QWAudioRingBuffer.h) — called when injected media
/// stops/reloads so stale audio from a previous clip doesn't linger and get played into a new
/// broadcast.
- (void)reset;

@end

/// Realtime-safe C entry point for audiounit.m's AudioUnitRender hook. Never allocates, never
/// touches the ObjC runtime, never blocks. Fills every buffer in `ioData` from the
/// correspondingly-configured ring buffer(s) and returns true only if *all* of them had enough
/// data (all-or-nothing, so multi-channel audio can't drift out of sync from a partial
/// underrun); otherwise returns false and leaves `ioData` completely untouched, so the caller
/// should fall back to passing its real audio through.
bool QWAudioUnitBridgeReadInto(AudioBufferList *ioData);

NS_ASSUME_NONNULL_END
