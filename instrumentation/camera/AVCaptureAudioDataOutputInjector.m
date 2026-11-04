#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import "AVCaptureAudioDataOutputInjector.h"
#import "MockMediaSource.h"
#import "utils.h"

// Log counter — resets when a new wrapper is created (i.e. per recording session)
static int sSettingsLogCount = 0;

#pragma mark - AudioDataOutputDelegateWrapper

/**
 * Wrapper that intercepts real microphone audio samples and replaces them
 * with injected audio from MockMediaSource's ring buffer, converting from
 * the tap's format (e.g. 44.1kHz stereo float32) to the mic's format
 * (e.g. 48kHz mono int16) using AVAudioConverter.
 */
@interface AudioDataOutputDelegateWrapper : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> originalDelegate;
@property (nonatomic, assign) int passthroughLogCount;
@end

@implementation AudioDataOutputDelegateWrapper

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    // Capture the mic's native format from the first real sample buffer,
    // so we can convert our injected audio to match.
    if (!mediaSource.targetAudioFormatReady) {
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
            if (asbd) {
                [mediaSource configureTargetAudioFormat:asbd];
            }
        }
    }

    // Forward real mic audio until injected audio starts flowing.
    // This prevents a gap where the app receives no audio and abandons the recording.
    if (!mediaSource.injectedAudioFlowing) {
        if (++_passthroughLogCount <= 3) {
            NSLog(@"QAWolf:AudioDataOutput: Passing through mic audio #%d (tap not ready)", _passthroughLogCount);
        }
        id<AVCaptureAudioDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
        if (delegate) {
            [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
        return;
    }
    // Drop real mic audio — injected audio is now flowing via the tap.
}

#pragma mark - Transparent forwarding

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    id delegate = self.originalDelegate;
    return delegate ? [delegate respondsToSelector:aSelector] : NO;
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id delegate = self.originalDelegate;
    if (delegate && [delegate respondsToSelector:aSelector]) return delegate;
    return [super forwardingTargetForSelector:aSelector];
}

@end

#pragma mark - AVCaptureAudioDataOutput Injection

@implementation AVCaptureAudioDataOutput (AudioInjection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(setSampleBufferDelegate:queue:)
                   swizzledSelector:@selector(audio_setSampleBufferDelegate:queue:)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(setAudioSettings:)
                   swizzledSelector:@selector(audio_setAudioSettings:)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(audioSettings)
                   swizzledSelector:@selector(audio_audioSettings)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(recommendedAudioSettingsForAssetWriter:writingTo:)
                   swizzledSelector:@selector(audio_recommendedAudioSettingsForAssetWriter:writingTo:)];
        NSLog(@"QAWolf:AudioDataOutput: Swizzling complete");
    });
}

- (void)audio_setAudioSettings:(NSDictionary *)audioSettings {
    NSLog(@"QAWolf:AudioDataOutput: setAudioSettings called with settings=%@", audioSettings);

    // Store the settings using associated object (audioSettings property unavailable on iOS)
    objc_setAssociatedObject(self, @selector(qawolf_audioSettings), audioSettings, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Call original to preserve normal behavior
    [self audio_setAudioSettings:audioSettings];
}

- (NSDictionary *)qawolf_audioSettings {
    return objc_getAssociatedObject(self, @selector(qawolf_audioSettings));
}

/// Returns audio settings that reflect the tap's actual output format when injection is active.
/// The consumer (e.g. AVAssetWriter setup) reads this to know what PCM format samples will arrive in.
- (NSDictionary *)audio_audioSettings {
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];
    if ([mediaSource hasAudio] && (mediaSource.targetAudioFormatReady || mediaSource.audioTapFormatReady)) {
        // Prefer the mic's native format (what we convert to), fall back to tap format
        AudioStreamBasicDescription asbd = mediaSource.targetAudioFormatReady
            ? mediaSource.targetAudioFormat : mediaSource.audioTapFormat;
        NSDictionary *settings = @{
            AVFormatIDKey: @(asbd.mFormatID),
            AVSampleRateKey: @(asbd.mSampleRate),
            AVNumberOfChannelsKey: @(asbd.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: @(asbd.mBitsPerChannel),
            AVLinearPCMIsFloatKey: @((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0),
            AVLinearPCMIsBigEndianKey: @((asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0),
            AVLinearPCMIsNonInterleaved: @((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0),
        };
        if (++sSettingsLogCount <= 3) {
            NSLog(@"QAWolf:AudioDataOutput: audioSettings returning injected format: %@", settings);
        }
        return settings;
    }
    // Tap not ready yet — return original settings
    return [self audio_audioSettings];
}

- (NSDictionary *)audio_recommendedAudioSettingsForAssetWriter:(AVAssetWriter *)assetWriter
                                                     writingTo:(AVFileType)fileType {
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];
    if ([mediaSource hasAudio] && (mediaSource.targetAudioFormatReady || mediaSource.audioTapFormatReady)) {
        AudioStreamBasicDescription asbd = mediaSource.targetAudioFormatReady
            ? mediaSource.targetAudioFormat : mediaSource.audioTapFormat;
        return @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @(asbd.mSampleRate),
            AVNumberOfChannelsKey: @(asbd.mChannelsPerFrame),
            AVEncoderBitRateKey: @(128000),
        };
    }
    return [self audio_recommendedAudioSettingsForAssetWriter:assetWriter writingTo:fileType];
}

- (void)audio_setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                                queue:(dispatch_queue_t)queue {

    NSLog(@"QAWolf:AudioDataOutput: setSampleBufferDelegate called with delegate=%p, queue=%p", delegate, queue);

    // Guard: if the delegate IS our wrapper, pass through to avoid re-wrapping
    if ([delegate isKindOfClass:[AudioDataOutputDelegateWrapper class]]) {
        [self audio_setSampleBufferDelegate:delegate queue:queue];
        return;
    }

    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    if ([mediaSource hasAudio] && delegate != nil) {
        NSLog(@"QAWolf:AudioDataOutput: Audio injection enabled (push mode)");
        sSettingsLogCount = 0;

        // Register delegate so MockMediaSource can push converted audio directly
        NSDictionary *audioSettings = [self qawolf_audioSettings];
        [mediaSource registerAudioDelegate:delegate
                                    output:self
                             audioSettings:audioSettings
                             callbackQueue:queue];

        // Start playback so the audio tap delivers samples
        [mediaSource startMediaPlayback];

        // Set wrapper as session delegate. The wrapper intercepts real mic samples
        // and replaces the audio data with PCM from the ring buffer, keeping the
        // mic's original timestamps for perfect A/V sync.
        AudioDataOutputDelegateWrapper *wrapper = [[AudioDataOutputDelegateWrapper alloc] init];
        wrapper.originalDelegate = delegate;
        objc_setAssociatedObject(self, @selector(audioWrapper), wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self audio_setSampleBufferDelegate:wrapper queue:queue];

        NSLog(@"QAWolf:AudioDataOutput: Audio injection started (delegate=%p)", delegate);
    } else if (delegate == nil) {
        NSLog(@"QAWolf:AudioDataOutput: Audio delegate cleared");
        objc_setAssociatedObject(self, @selector(audioWrapper), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self audio_setSampleBufferDelegate:nil queue:queue];
    } else {
        NSLog(@"QAWolf:AudioDataOutput: No audio to inject - using real microphone");
        [self audio_setSampleBufferDelegate:delegate queue:queue];
    }
}

@end
