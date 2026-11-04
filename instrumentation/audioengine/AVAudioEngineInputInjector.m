//
//  AVAudioEngineInputInjector.m
//  instrumentation
//
//  AVAudioEngine mic-capture audio injection.
//
//  Makes ios.injectAudio() reach apps that consume the microphone through
//  AVAudioEngine.inputNode (e.g. Apple Speech Recognition / SFSpeechRecognizer, custom
//  real-time ML audio processing, level meters) -- regardless of whether the app installs
//  a tap, connects the input node into a processing graph, or drives it some other way.
//
//  Why audiounit.m doesn't already cover this: that hook fishhooks the exported AudioToolbox
//  C symbols AudioUnitInitialize/AudioUnitRender. AVAudioEngine wraps its input node's
//  underlying AURemoteIO/VoiceProcessingIO in an internal AUAudioUnit adapter and drives the
//  render graph through block-based internalRenderBlock calls, bypassing those public C
//  symbols entirely -- confirmed via device syslog on a live AVAudioEngine mic-capture session
//  showing zero audiounit.m markers of any kind, including at AudioUnitInitialize time.
//
//  Approach: instead of fishhooking exported C symbols, swizzle the public Objective-C
//  -[AVAudioEngine startAndReturnError:] method, then reach the *real* underlying AudioUnit
//  via the public, documented AVAudioIONode.audioUnit property and register a render
//  notification directly on it with the public AudioUnitAddRenderNotify API. A render-notify
//  callback is invoked by the AudioUnit instance's own implementation as part of doing its
//  own rendering work -- it is not dispatched by the AudioUnitRender() trampoline -- so it
//  still fires even though AVAudioEngine never calls that trampoline. This is the one point
//  every AVAudioEngine mic consumer shares (tap, direct graph connection, or otherwise), so
//  it needs no cooperation from the app.
//
//  Also fishhooks AudioComponentInstanceDispose (same public symbol audiounit.m already
//  hooks -- fishhook chains multiple independent rebinds of the same symbol correctly
//  regardless of constructor order, since each rebind captures whatever is currently bound
//  as its "original" before installing its own replacement) to untrack disposed units, the
//  same lifecycle discipline audiounit.m already has. Without this, a unit tracked here would
//  never be forgotten: an app that recreates its AVAudioEngine repeatedly (common across
//  SFSpeechRecognizer sessions) would eventually fill the tracked-unit table, or worse, a
//  disposed unit's freed pointer could be reused by an unrelated new unit and wrongly match
//  as "already tracked", silently skipping it.
//
//  Reuses audiounit.m's QWAudioUnitBridge/QWAudioUnitBridgeReadInto unchanged -- the
//  AURenderCallback signature already matches what QWAudioUnitBridgeReadInto expects, and
//  MockMediaSource already pushes injected audio into the bridge unconditionally whenever
//  media is playing (not gated on any particular consumer being registered).
//
//  Open risks / not yet validated at scale:
//  - Mutating ioData from a render-notify callback is a commonly used real-world technique,
//    but Apple's docs don't officially bless consumers relying on it -- unlike audiounit.m's
//    render hook, which fully owns the call by hooking the render function itself.
//  - QWAudioUnitBridge is a single, process-wide singleton shared with audiounit.m. An app
//    that drives *both* a raw-AudioUnit mic path (tracked by audiounit.m) and an AVAudioEngine
//    path (tracked here) in the same process would have both hooks' configureTargetFormat:
//    calls race for the bridge's one active target format, with no error signaled -- whichever
//    call lands last wins, and the other consumer's render callback keeps reading a now-
//    mismatched generation. Not fixed here: doing so safely needs the bridge to support
//    multiple independent consumers/formats, which is a larger change than this hook should
//    make unilaterally. In practice this requires an app to run two independent mic-capture
//    architectures against the microphone at once, which iOS's single-active-input
//    AVAudioSession model makes unlikely -- but it's a known gap, not a solved one.
//  - -[AVAudioEngine inputNode] lazily creates the engine's singleton input node the first
//    time it's read. To avoid unnecessarily creating (and probing the AudioUnit of) an input
//    node on engines that are output-only (e.g. music/game engines with no mic use at all),
//    this only proceeds when the current AVAudioSession category indicates the app intends
//    to record. Apps that use AVAudioEngine mic input necessarily need such a category
//    active anyway (mic permission itself requires it), so this doesn't reduce coverage of
//    the actual target apps.
//

#import "AVAudioEngineInputInjector.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import "utils.h"
#import "../fishhook.h"
#import "../QWAudioUnitTracking.h"
#import "../audiounit/QWAudioUnitBridge.h"

// AudioUnit pointers we've already registered a render notify on, so repeated
// -startAndReturnError: calls against the same underlying unit (interruption/resume,
// route changes, a second start after a manual stop, etc.) don't stack duplicate
// AudioUnitAddRenderNotify registrations -- each stacked registration would fire once per
// render, multiplying QWAudioUnitBridgeReadInto calls against the same buffer. Entries are
// removed by my_AudioComponentInstanceDispose below when the unit is torn down.
static QWTrackedAudioUnitSet gTrackedInputUnits = QW_TRACKED_AUDIO_UNIT_SET_INIT;

// Logged once as a lightweight liveness signal, not on every render call (realtime hot path).
static _Atomic bool loggedInputInjectionStart = false;
// Liveness/diagnostic markers, each logged only once (compare-exchange guarded, so the
// realtime hot path still never logs on steady-state calls): confirms whether the callback
// is invoked at all, and if so, whether it's reaching (and failing) the ring-buffer read
// versus never getting past the PostRender/bus/ioData gates in the first place.
static _Atomic bool loggedFirstCall = false;
static _Atomic bool loggedFirstUnderrun = false;

// AURenderCallback registered via AudioUnitAddRenderNotify. Fired by the AudioUnit
// instance's own implementation, both before and after it renders -- realtime thread, same
// constraints as audiounit.m's render hook: no allocation, no locks beyond the ring buffer's
// own lock-free read, no ObjC runtime calls in the hot path.
static OSStatus qw_inputRenderNotify(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                                      UInt32 inNumberFrames, AudioBufferList *ioData) {
    {
        bool expected = false;
        if (atomic_compare_exchange_strong(&loggedFirstCall, &expected, true)) {
            NSLog(@"QAWolf:audioengine: render notify first call -- flags=0x%x bus=%u frames=%u ioData=%p numBuffers=%u",
                  (unsigned)*ioActionFlags, (unsigned)inBusNumber, (unsigned)inNumberFrames,
                  (void *)ioData, ioData ? (unsigned)ioData->mNumberBuffers : 0);
        }
    }

    // Only the post-render call has real captured mic audio in ioData; the pre-render call
    // fires before the unit has filled anything and must be left alone.
    if (!(*ioActionFlags & kAudioUnitRenderAction_PostRender)) return noErr;
    if (inBusNumber != 1) return noErr; // element/bus 1 = mic-capture side, same convention as audiounit.m
    if (ioData == NULL) return noErr;

    BOOL overwrote = QWAudioUnitBridgeReadInto(ioData);
    if (overwrote) {
        bool expected = false;
        if (atomic_compare_exchange_strong(&loggedInputInjectionStart, &expected, true)) {
            NSLog(@"QAWolf:audioengine: began overwriting AVAudioEngine input bus=1 from injected audio ring buffer");
        }
    } else {
        bool expected = false;
        if (atomic_compare_exchange_strong(&loggedFirstUnderrun, &expected, true)) {
            NSLog(@"QAWolf:audioengine: first ring-buffer underrun on bus=1 (reached the read, no data ready yet)");
        }
    }
    return noErr;
}

// Best-effort signal that this app intends to use the microphone at all, so we don't touch
// -[AVAudioEngine inputNode] (which lazily creates the engine's singleton input node) on
// engines that are output-only. Apps that drive AVAudioEngine mic input need one of these
// categories active anyway (mic permission requires it), so this doesn't cost us coverage.
static BOOL qw_sessionCategoryAllowsRecording(void) {
    NSString *category = [AVAudioSession sharedInstance].category;
    return [category isEqualToString:AVAudioSessionCategoryRecord] ||
           [category isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
           [category isEqualToString:AVAudioSessionCategoryMultiRoute];
}

// Only the public AudioComponentInstanceDispose C symbol is fishhooked (everything else here
// is an Objective-C swizzle) -- see the file header for why chaining with audiounit.m's own
// hook of the same symbol is safe.
static OSStatus (*original_AudioComponentInstanceDispose)(AudioComponentInstance);

static OSStatus my_AudioComponentInstanceDispose(AudioComponentInstance instance) {
    OSStatus status = original_AudioComponentInstanceDispose(instance);
    QWTrackedAudioUnitSetRemove(&gTrackedInputUnits, instance);
    return status;
}

@implementation AVAudioEngine (QAWolfAVAudioEngineInputInjection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:[AVAudioEngine class]
                   originalSelector:@selector(startAndReturnError:)
                   swizzledSelector:@selector(qw_audioEngine_startAndReturnError:)];
        rebind_single_symbol("AudioComponentInstanceDispose", (void *)my_AudioComponentInstanceDispose,
                              (void **)&original_AudioComponentInstanceDispose);
        NSLog(@"QAWolf:audioengine: swizzling complete");
    });
}

- (BOOL)qw_audioEngine_startAndReturnError:(NSError **)outError {
    BOOL started = [self qw_audioEngine_startAndReturnError:outError];
    if (!started) return started;
    if (!qw_sessionCategoryAllowsRecording()) return started;

    AVAudioInputNode *inputNode = self.inputNode;
    AudioUnit unit = inputNode.audioUnit;
    if (unit == NULL) return started; // input not wired to hardware (yet), or manual rendering mode

    if (QWTrackedAudioUnitSetContains(&gTrackedInputUnits, unit)) return started; // already registered

    // Element 1 / Output scope is the format this unit hands back on its mic-capture bus --
    // same property audiounit.m reads at AudioUnitInitialize time. Read (and only track +
    // register the render notify) if this succeeds: tracking a unit whose format we couldn't
    // read would both let qw_inputRenderNotify overwrite its buffer with data converted for
    // some *other* unit's format, and permanently prevent retrying on a later start (since
    // the unit would already show as tracked).
    AudioStreamBasicDescription micFormat;
    UInt32 size = sizeof(micFormat);
    OSStatus formatStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                  kAudioUnitScope_Output, 1, &micFormat, &size);
    if (formatStatus != noErr) {
        NSLog(@"QAWolf:audioengine: startAndReturnError: failed to read mic-capture format for "
              "unit=%p: %d -- not registering render notify", (void *)unit, (int)formatStatus);
        return started;
    }

    if (!QWTrackedAudioUnitSetAddIfNew(&gTrackedInputUnits, unit, "audioengine")) return started;

    [[QWAudioUnitBridge sharedInstance] configureTargetFormat:&micFormat];

    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription desc = {0};
    if (component != NULL) AudioComponentGetDescription(component, &desc);
    NSLog(@"QAWolf:audioengine: startAndReturnError: unit=%p type=%@ subType=%@ "
          "sampleRate=%.0f channels=%u bitsPerChannel=%u",
          (void *)unit, QWFourCCToString(desc.componentType), QWFourCCToString(desc.componentSubType),
          micFormat.mSampleRate, (unsigned)micFormat.mChannelsPerFrame, (unsigned)micFormat.mBitsPerChannel);

    OSStatus notifyStatus = AudioUnitAddRenderNotify(unit, qw_inputRenderNotify, NULL);
    if (notifyStatus != noErr) {
        // Undo the tracking add above -- leaving this unit marked as tracked with no render
        // notify actually registered would make every future -startAndReturnError: call for
        // it bail out early as "already registered" and never retry.
        QWTrackedAudioUnitSetRemove(&gTrackedInputUnits, unit);
        NSLog(@"QAWolf:audioengine: AudioUnitAddRenderNotify failed: %d", (int)notifyStatus);
    } else {
        NSLog(@"QAWolf:audioengine: registered render notify on unit=%p", (void *)unit);
    }

    return started;
}

@end
