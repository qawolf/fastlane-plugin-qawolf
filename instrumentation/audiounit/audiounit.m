//
//  audiounit.m
//  instrumentation
//
//  See audiounit.h for context. Hooks the mic-capture Audio Unit's render call and
//  substitutes audio queued by QWAudioUnitBridge (fed from MockMediaSource's existing
//  injected-media pipeline) for the real microphone input, so `ios.injectAudio()` reaches
//  WebRTC/Agora broadcasts the same way it already reaches AVCaptureAudioDataOutput/
//  AVAudioRecorder-based mic consumption.
//
//  Only three public AudioToolbox C functions are hooked — AudioUnitInitialize,
//  AudioUnitRender, AudioComponentInstanceDispose. No need to also hook the
//  AudioComponentInstanceNew/AudioComponentInstantiate creation APIs: Apple's documented
//  AudioUnit lifecycle guarantees AudioUnitInitialize fires (and must succeed) before any
//  AudioUnitRender call for that unit, so it's a reliable, non-realtime place to both
//  identify the unit and read its negotiated stream format.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import "../fishhook.h"
#import "../QWAudioUnitTracking.h"
#import "QWAudioUnitBridge.h"

// Original function pointers
static OSStatus (*original_AudioUnitInitialize)(AudioUnit);
static OSStatus (*original_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*original_AudioComponentInstanceDispose)(AudioComponentInstance);

// Units identified as kAudioUnitType_Output (RemoteIO or VoiceProcessingIO) at Initialize
// time. See QWAudioUnitTracking.h for the realtime-safety contract this relies on.
static QWTrackedAudioUnitSet gTrackedUnits = QW_TRACKED_AUDIO_UNIT_SET_INIT;

// AudioUnitInitialize is guaranteed by Apple's documented AudioUnit lifecycle to fire before
// any AudioUnitRender call for that unit — confirmed by device trace against Agora too. So
// this is a reliable, non-realtime place to identify + track the unit and hand its negotiated
// mic-capture format to QWAudioUnitBridge.
static OSStatus my_AudioUnitInitialize(AudioUnit unit) {
    OSStatus status = original_AudioUnitInitialize(unit);
    if (status != noErr) return status;

    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (component == NULL) return status;

    AudioComponentDescription desc;
    if (AudioComponentGetDescription(component, &desc) != noErr) return status;

    if (desc.componentType != kAudioUnitType_Output) return status;
    BOOL isVPIO = (desc.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
    BOOL isRemoteIO = (desc.componentSubType == kAudioUnitSubType_RemoteIO);
    // Restrict to the two subtypes we actually understand -- an unrelated Output-type unit
    // (e.g. a generic/HAL/default output used for something else entirely) could also render
    // on bus 1, and we don't want to hijack that with mic-injection logic meant only for
    // RemoteIO/VoiceProcessingIO mic-capture units.
    if (!isVPIO && !isRemoteIO) return status;

    QWTrackedAudioUnitSetAddIfNew(&gTrackedUnits, unit, "audiounit");
    NSLog(@"QAWolf:audiounit:AudioUnitInitialize: tracking unit=%p type=%@ subType=%@%@",
          (void *)unit, QWFourCCToString(desc.componentType), QWFourCCToString(desc.componentSubType),
          isVPIO ? @" (VoiceProcessingIO)" : (isRemoteIO ? @" (RemoteIO)" : @""));

    // Element 1 / Output scope is the format AudioUnitRender(bus=1) hands back to the caller.
    // Feed it to the bridge so it knows what to convert injected media into.
    AudioStreamBasicDescription micOutputFormat;
    UInt32 size = sizeof(micOutputFormat);
    OSStatus formatStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                  kAudioUnitScope_Output, 1, &micOutputFormat, &size);
    if (formatStatus == noErr) {
        [[QWAudioUnitBridge sharedInstance] configureTargetFormat:&micOutputFormat];
        NSLog(@"QAWolf:audiounit:AudioUnitInitialize: mic-capture format sampleRate=%.0f channels=%u bitsPerChannel=%u",
              micOutputFormat.mSampleRate, (unsigned)micOutputFormat.mChannelsPerFrame,
              (unsigned)micOutputFormat.mBitsPerChannel);
    } else {
        NSLog(@"QAWolf:audiounit:AudioUnitInitialize: failed to read mic-capture format: %d", (int)formatStatus);
    }

    return status;
}

static OSStatus my_AudioComponentInstanceDispose(AudioComponentInstance instance) {
    OSStatus status = original_AudioComponentInstanceDispose(instance);
    QWTrackedAudioUnitSetRemove(&gTrackedUnits, instance);
    return status;
}

// Logged once as a lightweight liveness signal, not on every render call (that would violate
// the "no logging in the realtime hot path" constraint — this NSLog only ever fires the one
// time the atomic flag flips, all other calls take the branch-not-taken fast path).
static _Atomic bool loggedInjectionStart = false;

static OSStatus my_AudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                    UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = original_AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (status == noErr && inBusNumber == 1 && QWTrackedAudioUnitSetContains(&gTrackedUnits, unit)) {
        // QWAudioUnitBridgeReadInto is the only realtime-safe entry point into the bridge: a
        // single acquire-load of the current ring-buffer generation plus (for non-interleaved
        // multi-channel formats) an all-or-nothing multi-buffer read — no allocation, no
        // locks, no ObjC runtime calls. On underrun it leaves `ioData` exactly as the real
        // render call filled it, so real microphone audio passes through untouched for that
        // one buffer.
        BOOL overwrote = QWAudioUnitBridgeReadInto(ioData);
        if (overwrote) {
            bool expected = false;
            if (atomic_compare_exchange_strong(&loggedInjectionStart, &expected, true)) {
                NSLog(@"QAWolf:audiounit:AudioUnitRender: began overwriting unit=%p bus=1 from injected audio ring buffer", (void *)unit);
            }
        }
    }
    return status;
}

__attribute__((constructor))
static void initializeAudioUnitInjection(void) {
    NSLog(@"QAWolf:audiounit:initializeAudioUnitInjection was called");
    rebind_single_symbol("AudioUnitInitialize", (void *)my_AudioUnitInitialize, (void **)&original_AudioUnitInitialize);
    rebind_single_symbol("AudioUnitRender", (void *)my_AudioUnitRender, (void **)&original_AudioUnitRender);
    rebind_single_symbol("AudioComponentInstanceDispose", (void *)my_AudioComponentInstanceDispose, (void **)&original_AudioComponentInstanceDispose);
}
