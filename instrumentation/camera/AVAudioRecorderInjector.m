//
//  AVAudioRecorderInjector.m
//  ios-agent
//
//  Swizzles AVAudioRecorder to record audio from MockMediaSource
//

#import "AVAudioRecorderInjector.h"
#import <objc/runtime.h>
#import "MediaInjectionConfigManager.h"
#import "MockMediaSource.h"
#import "utils.h"

// Syslog redacts %@ strings but not %c, so four-char codes stay readable.
#define QW_FOURCC(code) (char)((code) >> 24), (char)((code) >> 16), (char)((code) >> 8), (char)(code)

// AVAudioRecorder picks the container from the URL extension. AVAssetWriter cannot write
// some of them (.aac is ADTS), so the recording goes through ExtAudioFile like the real one.
static AudioFileTypeID QWAudioFileTypeForURL(NSURL *url) {
    NSDictionary<NSString *, NSNumber *> *fileTypes = @{
        @"aac": @(kAudioFileAAC_ADTSType),
        @"m4a": @(kAudioFileM4AType),
        @"mp4": @(kAudioFileMPEG4Type),
        @"3gp": @(kAudioFile3GPType),
        @"caf": @(kAudioFileCAFType),
        @"wav": @(kAudioFileWAVEType),
        @"aif": @(kAudioFileAIFFType),
        @"aiff": @(kAudioFileAIFFType),
        @"aifc": @(kAudioFileAIFCType),
    };
    NSNumber *fileType = fileTypes[url.pathExtension.lowercaseString];
    return fileType ? fileType.unsignedIntValue : kAudioFileM4AType;
}

static AudioStreamBasicDescription QWFileFormatFromRecorderSettings(NSDictionary *settings, AudioFileTypeID fileType) {
    BOOL pcmContainer = fileType == kAudioFileWAVEType || fileType == kAudioFileAIFFType;

    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mFormatID = settings[AVFormatIDKey] ? [settings[AVFormatIDKey] unsignedIntValue]
                                               : (pcmContainer ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC);
    format.mSampleRate = [settings[AVSampleRateKey] doubleValue] ?: 44100.0;
    format.mChannelsPerFrame = [settings[AVNumberOfChannelsKey] unsignedIntValue] ?: 2;

    if (format.mFormatID == kAudioFormatLinearPCM) {
        UInt32 bitDepth = [settings[AVLinearPCMBitDepthKey] unsignedIntValue] ?: 16;
        BOOL isFloat = [settings[AVLinearPCMIsFloatKey] boolValue];
        // WAVE is always little-endian and AIFF always big-endian.
        BOOL isBigEndian = fileType == kAudioFileAIFFType ||
            (fileType != kAudioFileWAVEType && [settings[AVLinearPCMIsBigEndianKey] boolValue]);
        format.mFormatFlags = (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                              kAudioFormatFlagIsPacked | (isBigEndian ? kAudioFormatFlagIsBigEndian : 0);
        format.mBitsPerChannel = bitDepth;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = format.mBytesPerPacket = bitDepth / 8 * format.mChannelsPerFrame;
    } else {
        UInt32 size = sizeof(format);
        AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &format);
    }
    return format;
}

// All file access runs on writerQueue.
@interface AudioRecordingState : NSObject
@property (nonatomic, assign) ExtAudioFileRef file;
@property (nonatomic, assign) AudioFileTypeID fileType;
@property (nonatomic, strong) NSNumber *encoderBitRate;
@property (nonatomic, assign) BOOL clientFormatSet;
@property (nonatomic, assign) AudioStreamBasicDescription clientFormat;
@property (nonatomic, assign) SInt64 framesWritten;
@property (nonatomic, assign) int writeFailures;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, strong) dispatch_queue_t writerQueue;
@property (nonatomic, assign) NSTimeInterval scheduledStartTime;
@property (nonatomic, assign) NSTimeInterval scheduledDuration;
@end

@implementation AudioRecordingState

- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.file) {
        return;
    }

    CMAudioFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *sampleFormat =
        formatDescription ? CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) : NULL;
    if (!sampleFormat) {
        return;
    }

    // The file converts from the format MockMediaSource delivers to the format the app asked for.
    if (!self.clientFormatSet) {
        OSStatus status = ExtAudioFileSetProperty(self.file, kExtAudioFileProperty_ClientDataFormat,
                                                  sizeof(*sampleFormat), sampleFormat);
        if (status != noErr) {
            NSLog(@"QAWolf:AudioRecorder: Failed to set client format: %d", (int)status);
            return;
        }
        self.clientFormat = *sampleFormat;
        self.clientFormatSet = YES;
        [self applyEncoderBitRate];
    } else if (memcmp(sampleFormat, &_clientFormat, sizeof(*sampleFormat)) != 0) {
        if (++self.writeFailures <= 3) {
            NSLog(@"QAWolf:AudioRecorder: Dropping sample in a different format (%.0f Hz, %u ch)",
                  sampleFormat->mSampleRate, (unsigned int)sampleFormat->mChannelsPerFrame);
        }
        return;
    }

    size_t bufferListSize = 0;
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, &bufferListSize, NULL, 0,
                                                            NULL, NULL, 0, NULL);
    AudioBufferList *bufferList = malloc(bufferListSize);
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, NULL, bufferList, bufferListSize, NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer);
    if (status == noErr) {
        UInt32 frames = (UInt32)CMSampleBufferGetNumSamples(sampleBuffer);
        status = ExtAudioFileWrite(self.file, frames, bufferList);
        if (status == noErr) {
            self.framesWritten += frames;
        }
    }
    if (status != noErr && ++self.writeFailures <= 3) {
        NSLog(@"QAWolf:AudioRecorder: Failed to write sample: %d", (int)status);
    }
    if (blockBuffer) {
        CFRelease(blockBuffer);
    }
    free(bufferList);
}

// The file's encoder exists only after the client format is set.
- (void)applyEncoderBitRate {
    if (!self.encoderBitRate) {
        return;
    }
    AudioConverterRef converter = NULL;
    UInt32 size = sizeof(converter);
    if (ExtAudioFileGetProperty(self.file, kExtAudioFileProperty_AudioConverter, &size, &converter) != noErr || !converter) {
        return;
    }
    UInt32 bitRate = self.encoderBitRate.unsignedIntValue;
    OSStatus status = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
    if (status != noErr) {
        NSLog(@"QAWolf:AudioRecorder: Encoder rejected bit rate %u: %d", (unsigned int)bitRate, (int)status);
        return;
    }
    CFArrayRef converterConfig = NULL;
    ExtAudioFileSetProperty(self.file, kExtAudioFileProperty_ConverterConfig, sizeof(converterConfig), &converterConfig);
}

- (void)finish {
    if (!self.file) {
        return;
    }
    OSStatus status = ExtAudioFileDispose(self.file);
    self.file = NULL;
    NSLog(@"QAWolf:AudioRecorder: Recording finished: '%c%c%c%c' file, %lld frames, status %d",
          QW_FOURCC(self.fileType), self.framesWritten, (int)status);
}

@end

@interface AVAudioRecorder (AudioRecordingState) <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AudioRecordingState *recordingState;
@end

@implementation AVAudioRecorder (AudioInjection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(record)
                   swizzledSelector:@selector(audio_record)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(recordAtTime:)
                   swizzledSelector:@selector(audio_recordAtTime:)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(recordForDuration:)
                   swizzledSelector:@selector(audio_recordForDuration:)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(recordAtTime:forDuration:)
                   swizzledSelector:@selector(audio_recordAtTime:forDuration:)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(stop)
                   swizzledSelector:@selector(audio_stop)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(isRecording)
                   swizzledSelector:@selector(audio_isRecording)];
        NSLog(@"QAWolf:AudioRecorder: Swizzling complete");
    });
}

#pragma mark - Associated Object Properties

- (AudioRecordingState *)recordingState {
    return objc_getAssociatedObject(self, @selector(recordingState));
}

- (void)setRecordingState:(AudioRecordingState *)state {
    objc_setAssociatedObject(self, @selector(recordingState), state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Recording Control Methods

- (BOOL)audio_record {
    return [self startRecordingWithScheduledTime:0 duration:0];
}

- (BOOL)audio_recordAtTime:(NSTimeInterval)time {
    return [self startRecordingWithScheduledTime:time duration:0];
}

- (BOOL)audio_recordForDuration:(NSTimeInterval)duration {
    return [self startRecordingWithScheduledTime:0 duration:duration];
}

- (BOOL)audio_recordAtTime:(NSTimeInterval)time forDuration:(NSTimeInterval)duration {
    return [self startRecordingWithScheduledTime:time duration:duration];
}

- (void)audio_stop {
    AudioRecordingState *state = self.recordingState;

    if (!state || !state.isActive) {
        [self audio_stop];
        return;
    }

    // Unregister delegate to stop receiving audio
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];
    [mediaSource registerAudioDelegate:nil output:(AVCaptureAudioDataOutput *)self audioSettings:nil callbackQueue:nil];

    // Stop and reset media playback to show placeholder
    [mediaSource stopMediaPlayback];

    // Clear recording state
    self.recordingState = nil;

    // AVAudioRecorder closes the file before stop returns, and apps read it right away.
    dispatch_sync(state.writerQueue, ^{
        [state finish];
    });
}

- (BOOL)audio_isRecording {
    AudioRecordingState *state = self.recordingState;
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    if ([mediaSource isMediaInjectionEnabled] && state && state.isActive) {
        return YES;
    }

    // Fall back to original implementation
    return [self audio_isRecording];
}

#pragma mark - Recording Setup

- (BOOL)startRecordingWithScheduledTime:(NSTimeInterval)scheduledTime duration:(NSTimeInterval)duration {
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    // Inject when the media has audio, else use the real microphone. media.json is polled
    // every 2 s and hasAudio waits for an async track load, so a recording started right
    // after injectAudio checks the file now and trusts an audio config's type.
    MediaInjectionConfigManager *configManager = [MediaInjectionConfigManager shared];
    if ([NSThread isMainThread]) {
        [configManager checkConfigFileChanges];
    }
    BOOL injectAudio = [mediaSource isMediaInjectionEnabled] &&
                       ([mediaSource hasAudio] || [configManager.currentConfig isAudio]);
    if (!injectAudio) {
        NSLog(@"QAWolf:AudioRecorder: No audio to inject - using real microphone");
        if (scheduledTime > 0 && duration > 0) {
            return [self audio_recordAtTime:scheduledTime forDuration:duration];
        } else if (scheduledTime > 0) {
            return [self audio_recordAtTime:scheduledTime];
        } else if (duration > 0) {
            return [self audio_recordForDuration:duration];
        } else {
            return [self audio_record];
        }
    }

    // Get recorder settings
    NSDictionary *settings = self.settings;
    NSURL *fileURL = self.url;

    if (!fileURL) {
        NSLog(@"QAWolf:AudioRecorder: No output URL specified");
        return NO;
    }

    // Unlink first: a prepared recorder may still hold the old file open.
    [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

    AudioFileTypeID fileType = QWAudioFileTypeForURL(fileURL);
    AudioStreamBasicDescription fileFormat = QWFileFormatFromRecorderSettings(settings, fileType);
    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)fileURL, fileType, &fileFormat, NULL,
                                                kAudioFileFlags_EraseFile, &file);
    if (status != noErr) {
        NSLog(@"QAWolf:AudioRecorder: Failed to create '%c%c%c%c' file with '%c%c%c%c' data: %d",
              QW_FOURCC(fileType), QW_FOURCC(fileFormat.mFormatID), (int)status);
        return NO;
    }

    // Create recording state
    AudioRecordingState *state = [[AudioRecordingState alloc] init];
    state.file = file;
    state.fileType = fileType;
    state.encoderBitRate = settings[AVEncoderBitRateKey];
    state.isActive = YES;
    state.startTime = CACurrentMediaTime();
    state.writerQueue = dispatch_queue_create("com.qawolf.audiorecorder.writer", DISPATCH_QUEUE_SERIAL);
    state.scheduledStartTime = scheduledTime;
    state.scheduledDuration = duration;
    self.recordingState = state;

    // Configure target audio format for MockMediaSource so it can convert tap audio
    // to PCM the file can encode. Use 16-bit PCM INTERLEAVED —
    // convertAudioTapData() writes to a single interleaved output buffer.
    if (![mediaSource targetAudioFormatReady]) {
        Float64 sampleRate = [settings[AVSampleRateKey] doubleValue] ?: 44100.0;
        UInt32 channels = (UInt32)([settings[AVNumberOfChannelsKey] unsignedIntValue] ?: 2);

        AudioStreamBasicDescription targetFormat;
        memset(&targetFormat, 0, sizeof(targetFormat));
        targetFormat.mSampleRate = sampleRate;
        targetFormat.mFormatID = kAudioFormatLinearPCM;
        targetFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        targetFormat.mBitsPerChannel = 16;
        targetFormat.mChannelsPerFrame = channels;
        targetFormat.mBytesPerFrame = 2 * channels; // 16-bit * channels, interleaved
        targetFormat.mBytesPerPacket = 2 * channels;
        targetFormat.mFramesPerPacket = 1;

        [mediaSource configureTargetAudioFormat:&targetFormat];
        NSLog(@"QAWolf:AudioRecorder: Configured target audio format: %.0f Hz, %u ch, 16-bit PCM interleaved",
              sampleRate, (unsigned int)channels);
    }

    // Register as delegate to receive audio from MockMediaSource
    // Don't specify capture settings - accept whatever format MockMediaSource provides
    // The file will handle format conversion from the source PCM to the output format
    [mediaSource registerAudioDelegate:self
                                output:(AVCaptureAudioDataOutput *)self
                         audioSettings:nil
                         callbackQueue:nil];

    // Start media playback now that recording has begun
    [mediaSource startMediaPlayback];
    NSLog(@"QAWolf:AudioRecorder: Media playback started for recording");

    // Handle scheduled duration
    if (duration > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.recordingState == state && state.isActive) {
                [self stop];
            }
        });
    }

    return YES;
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    AudioRecordingState *state = self.recordingState;
    if (!state) {
        return;
    }

    // Called on the audio render thread; keep file I/O off it.
    CFRetain(sampleBuffer);
    dispatch_async(state.writerQueue, ^{
        [state appendSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

@end
