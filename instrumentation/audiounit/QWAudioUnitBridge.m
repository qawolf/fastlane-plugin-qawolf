//
//  QWAudioUnitBridge.m
//  instrumentation
//

#import "QWAudioUnitBridge.h"
#import "QWAudioRingBuffer.h"
#import "../QWAudioConvert.h"
#import <stdatomic.h>
#import <stdlib.h>

#define QW_MAX_DST_CHANNELS 8

// Sized generously (0.5s of audio per channel, at the target format) — a live broadcast
// should never need more than a fraction of that in flight; this just absorbs producer/
// consumer jitter (and brief gaps like MockMediaSource's loop-seek at end-of-clip).
static const double kQWRingBufferSeconds = 0.5;

// One "generation" of ring buffers for a given target format: one buffer per destination
// channel for non-interleaved formats, or a single buffer for interleaved ones. Immutable
// once published (all fields set at creation, never mutated afterward) — only the pointer to
// it is ever swapped, so the realtime reader can dereference a generation it loaded via a
// single atomic acquire-load with no further synchronization needed for its contents.
typedef struct {
    QWAudioRingBuffer *buffers[QW_MAX_DST_CHANNELS];
    int channelCount;
    bool interleaved;
    AudioStreamBasicDescription format;
} QWAudioRingBufferSet;

// The generation the realtime reader (and the write side) currently use. Published via
// atomic_exchange in -configureTargetFormat: — never mutated in place.
static _Atomic(QWAudioRingBufferSet *) gActiveSet = NULL;

// The previous generation, retired but deliberately not yet freed — see
// -configureTargetFormat: for why one full generation of grace is enough to make freeing it
// safe. Owned exclusively by the non-realtime config path, guarded by configLock.
static QWAudioRingBufferSet *gRetiredSet = NULL;

static QWAudioRingBufferSet *qwCreateRingBufferSet(const AudioStreamBasicDescription *format) {
    QWAudioRingBufferSet *set = (QWAudioRingBufferSet *)calloc(1, sizeof(QWAudioRingBufferSet));
    if (set == NULL) return NULL;
    set->format = *format;

    bool nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = format->mChannelsPerFrame > 0 ? format->mChannelsPerFrame : 1;
    set->interleaved = !nonInterleaved;
    int wantedChannels = set->interleaved ? 1 : (int)channels;
    set->channelCount = wantedChannels < QW_MAX_DST_CHANNELS ? wantedChannels : QW_MAX_DST_CHANNELS;

    // Capacity is a per-buffer byte figure either way: for interleaved formats mBytesPerFrame
    // already covers all channels per frame; for non-interleaved formats Core Audio's ASBD
    // convention sets mBytesPerFrame to a single channel's frame size, and each buffer here
    // holds exactly one channel — so the same formula is correct for both cases.
    size_t capacityBytes = (size_t)(format->mBytesPerFrame * format->mSampleRate * kQWRingBufferSeconds);
    if (capacityBytes < 16384) capacityBytes = 16384;

    for (int i = 0; i < set->channelCount; i++) {
        QWAudioRingBuffer *rb = (QWAudioRingBuffer *)calloc(1, sizeof(QWAudioRingBuffer));
        if (rb == NULL || !QWAudioRingBufferInit(rb, capacityBytes)) {
            free(rb);
            for (int j = 0; j < i; j++) {
                QWAudioRingBufferFree(set->buffers[j]);
                free(set->buffers[j]);
            }
            free(set);
            return NULL;
        }
        set->buffers[i] = rb;
    }
    return set;
}

static void qwFreeRingBufferSet(QWAudioRingBufferSet *set) {
    if (set == NULL) return;
    for (int i = 0; i < set->channelCount; i++) {
        QWAudioRingBufferFree(set->buffers[i]);
        free(set->buffers[i]);
    }
    free(set);
}

@interface QWAudioUnitBridge ()
@property (nonatomic, assign) AudioStreamBasicDescription targetFormat;
@property (nonatomic, assign) BOOL targetFormatReady;
@property (nonatomic, assign) AudioStreamBasicDescription sourceFormat;
@property (nonatomic, assign) BOOL haveSourceFormat;
@property (nonatomic, assign) AudioConverterRef converter;
@property (nonatomic, strong) NSLock *configLock; // guards non-realtime config/converter/gRetiredSet mutation only
@end

// Diagnostic markers, each logged only once (compare-exchange guarded) so they can't add up
// to meaningful realtime-thread overhead even though pushSourceBuffer runs at audio-tap rate.
// Not otherwise part of steady-state operation -- purely to distinguish "never called",
// "called but format never configured", and "called, converts, but conversion/write fails"
// when investigating why injected audio isn't reaching a consumer.
static _Atomic bool loggedConfigureCalled = false;
static _Atomic bool loggedPushCalled = false;
static _Atomic bool loggedPushResult = false;

@implementation QWAudioUnitBridge

+ (instancetype)sharedInstance {
    static QWAudioUnitBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[QWAudioUnitBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _configLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)disposeConverterLocked {
    if (self.converter != NULL) {
        AudioConverterDispose(self.converter);
        self.converter = NULL;
    }
}

- (void)configureTargetFormat:(const AudioStreamBasicDescription *)format {
    {
        bool expected = false;
        if (atomic_compare_exchange_strong(&loggedConfigureCalled, &expected, true)) {
            NSLog(@"QAWolf:QWAudioUnitBridge: configureTargetFormat: called, format=%p sampleRate=%.0f channels=%u",
                  (const void *)format, format ? format->mSampleRate : 0, format ? (unsigned)format->mChannelsPerFrame : 0);
        }
    }
    if (format == NULL) return;
    [self.configLock lock];

    BOOL unchanged = self.targetFormatReady &&
        memcmp(&_targetFormat, format, sizeof(AudioStreamBasicDescription)) == 0;
    if (unchanged) {
        [self.configLock unlock];
        return;
    }

    // Allocate the new generation BEFORE committing any state change. If this fails, bail out
    // having touched nothing — targetFormat/targetFormatReady/converter/gActiveSet all stay
    // exactly as they were, so the bridge remains internally consistent (old format, old
    // buffers, old converter all still matching each other) rather than ending up with
    // targetFormatReady==YES pointing at a new format while gActiveSet still holds buffers
    // sized for the old one.
    QWAudioRingBufferSet *newSet = qwCreateRingBufferSet(format);
    if (newSet == NULL) {
        [self.configLock unlock];
        NSLog(@"QAWolf:QWAudioUnitBridge: target format reconfigure FAILED to allocate — keeping previous format/buffers active");
        return;
    }

    self.targetFormat = *format;
    self.targetFormatReady = YES;
    [self disposeConverterLocked];
    self.haveSourceFormat = NO; // force converter rebuild against the (possibly new) source format too

    // Swap in the new generation. Free only the generation retired at the PREVIOUS call
    // (not the one we just displaced) — that gives any realtime read already in flight,
    // which may have loaded the now-displaced pointer a moment before this exchange, a
    // full generation's worth of time (this entire call-to-call window) to finish before
    // its buffers are freed out from under it. A single render call is a tiny fraction of
    // that window, and reconfigures only happen on rare unit lifecycle events, not on
    // every render call, so this is comfortably safe without needing a lock the reader
    // would have to take.
    QWAudioRingBufferSet *displaced = atomic_exchange_explicit(&gActiveSet, newSet, memory_order_release);
    qwFreeRingBufferSet(gRetiredSet);
    gRetiredSet = displaced;

    [self.configLock unlock];

    NSLog(@"QAWolf:QWAudioUnitBridge: target format configured — %.0fHz %uch %ubit interleaved=%d",
          format->mSampleRate, (unsigned)format->mChannelsPerFrame, (unsigned)format->mBitsPerChannel,
          !(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved));
}

- (void)reset {
    QWAudioRingBufferSet *set = atomic_load_explicit(&gActiveSet, memory_order_acquire);
    if (set == NULL) return;
    for (int i = 0; i < set->channelCount; i++) {
        QWAudioRingBufferClear(set->buffers[i]);
    }
}

- (void)pushSourceBuffer:(AudioBufferList *)bufferList
             sourceFormat:(AudioStreamBasicDescription)sourceFormat
               frameCount:(UInt32)frameCount {
    {
        bool expected = false;
        if (atomic_compare_exchange_strong(&loggedPushCalled, &expected, true)) {
            NSLog(@"QAWolf:QWAudioUnitBridge: pushSourceBuffer: called, targetFormatReady=%d "
                  "bufferList=%p numBuffers=%u frameCount=%u srcSampleRate=%.0f srcChannels=%u",
                  self.targetFormatReady, (void *)bufferList,
                  bufferList ? (unsigned)bufferList->mNumberBuffers : 0, (unsigned)frameCount,
                  sourceFormat.mSampleRate, (unsigned)sourceFormat.mChannelsPerFrame);
        }
    }
    if (!self.targetFormatReady) return;
    if (bufferList == NULL || bufferList->mNumberBuffers == 0 || frameCount == 0) return;

    [self.configLock lock];

    if (!self.haveSourceFormat || memcmp(&_sourceFormat, &sourceFormat, sizeof(AudioStreamBasicDescription)) != 0) {
        [self disposeConverterLocked];
        self.sourceFormat = sourceFormat;

        // AudioConverter needs interleaved input — force that on our copy of the source format
        // description.
        AudioStreamBasicDescription interleavedSrc = sourceFormat;
        interleavedSrc.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
        interleavedSrc.mBytesPerFrame = interleavedSrc.mBytesPerPacket =
            (interleavedSrc.mBitsPerChannel / 8) * interleavedSrc.mChannelsPerFrame;

        AudioStreamBasicDescription dst = self.targetFormat;
        OSStatus status = AudioConverterNew(&interleavedSrc, &dst, &_converter);
        self.haveSourceFormat = (status == noErr);
        if (status != noErr) {
            NSLog(@"QAWolf:QWAudioUnitBridge: AudioConverterNew failed: %d", (int)status);
            [self.configLock unlock];
            return;
        }
        NSLog(@"QAWolf:QWAudioUnitBridge: converter created — %.0fHz %uch -> %.0fHz %uch",
              sourceFormat.mSampleRate, (unsigned)sourceFormat.mChannelsPerFrame,
              dst.mSampleRate, (unsigned)dst.mChannelsPerFrame);
    }

    AudioConverterRef converter = self.converter;
    AudioStreamBasicDescription dstFormat = self.targetFormat;

    if (converter == NULL) {
        [self.configLock unlock];
        return;
    }

    // Conversion and the ring-buffer write both stay under configLock, held continuously from
    // here through the end of this method. That makes this whole critical section mutually
    // exclusive with -configureTargetFormat:'s converter dispose and gActiveSet swap — so
    // `converter` can't be disposed out from under QWAudioConvertBuffer mid-call, and the
    // gActiveSet read below is guaranteed to match the `dstFormat` snapshot taken above (both
    // are from before or after the same reconfigure, never straddling one). None of this runs
    // on the realtime thread (only QWAudioUnitBridgeReadInto does, and it never takes this
    // lock), so holding it here doesn't affect realtime-thread latency.
    AudioBufferList *converted = NULL;
    UInt32 producedFrames = 0;
    BOOL convertedOK = QWAudioConvertBuffer(converter, bufferList, &sourceFormat, frameCount,
                                             &dstFormat, &converted, &producedFrames);
    {
        bool expected = false;
        if (atomic_compare_exchange_strong(&loggedPushResult, &expected, true)) {
            NSLog(@"QAWolf:QWAudioUnitBridge: pushSourceBuffer: first conversion result -- "
                  "convertedOK=%d producedFrames=%u convertedNumBuffers=%u",
                  convertedOK, (unsigned)producedFrames, convertedOK ? (unsigned)converted->mNumberBuffers : 0);
        }
    }
    if (convertedOK) {
        QWAudioRingBufferSet *set = atomic_load_explicit(&gActiveSet, memory_order_acquire);
        if (set != NULL) {
            int count = (int)converted->mNumberBuffers < set->channelCount ? (int)converted->mNumberBuffers : set->channelCount;
            for (int i = 0; i < count; i++) {
                QWAudioRingBufferWrite(set->buffers[i], (const uint8_t *)converted->mBuffers[i].mData,
                                        converted->mBuffers[i].mDataByteSize);
            }
        }
    }

    [self.configLock unlock];

    if (convertedOK) {
        QWAudioConvertFreeBufferList(converted);
    }
}

@end

bool QWAudioUnitBridgeReadInto(AudioBufferList *ioData) {
    if (ioData == NULL || ioData->mNumberBuffers == 0) return false;
    QWAudioRingBufferSet *set = atomic_load_explicit(&gActiveSet, memory_order_acquire);
    if (set == NULL) return false;

    if (set->interleaved) {
        AudioBuffer *buf = &ioData->mBuffers[0];
        if (buf->mData == NULL || buf->mDataByteSize == 0) return false;
        return QWAudioRingBufferRead(set->buffers[0], (uint8_t *)buf->mData, buf->mDataByteSize);
    }

    int count = (int)ioData->mNumberBuffers < set->channelCount ? (int)ioData->mNumberBuffers : set->channelCount;
    if (count == 0) return false;

    QWAudioRingBuffer *rbs[QW_MAX_DST_CHANNELS];
    uint8_t *dests[QW_MAX_DST_CHANNELS];
    size_t sizes[QW_MAX_DST_CHANNELS];
    for (int i = 0; i < count; i++) {
        AudioBuffer *buf = &ioData->mBuffers[i];
        if (buf->mData == NULL || buf->mDataByteSize == 0) return false;
        rbs[i] = set->buffers[i];
        dests[i] = (uint8_t *)buf->mData;
        sizes[i] = buf->mDataByteSize;
    }
    return QWAudioRingBufferReadAll(rbs, dests, sizes, count);
}
