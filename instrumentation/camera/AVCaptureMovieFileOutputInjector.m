//
//  AVCaptureMovieFileOutputInjector.m
//  instrumentation
//
//  Created by Andreas Lüdeke on 22.01.25.
//

#import "AVCaptureMovieFileOutputInjector.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "MockMediaSource.h"
#import "Utils.h"

@interface RecordingState : NSObject
@property (nonatomic, weak) id<AVCaptureFileOutputRecordingDelegate> delegate;
@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, assign) BOOL writerReady;
@property (nonatomic, strong) dispatch_queue_t writerQueue;
@property (nonatomic, assign) CVPixelBufferRef firstFramePixelBuffer;
@property (nonatomic, assign) CMTime firstFrameTimestamp;
@end

@implementation RecordingState
@end

@interface AVCaptureMovieFileOutput (MovieRecorder) <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, strong) RecordingState *recordingState;

@end

#pragma mark - AVCaptureMovieFileOutput Event-Driven Injection

@interface AVCaptureMovieFileOutput (EventDrivenVideoInjection) <MockMediaSourceVideoDelegate>
@end

@implementation AVCaptureMovieFileOutput (EventDrivenVideoInjection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(startRecordingToOutputFileURL:recordingDelegate:)
                   swizzledSelector:@selector(event_startRecordingToOutputFileURL:recordingDelegate:)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(stopRecording)
                   swizzledSelector:@selector(event_stopRecording)];
        [Utils swizzleMethodInClass:self
                   originalSelector:@selector(isRecording)
                   swizzledSelector:@selector(event_isRecording)];
        NSLog(@"QAWolf:MovieFileOutput: Swizzling complete (startRecording, stopRecording, isRecording)");
    });
}

- (void)event_startRecordingToOutputFileURL:(NSURL *)outputFileURL
                          recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    NSLog(@"QAWolf:MovieFileOutput: START RECORDING CALLED! URL: %@, Delegate: %@", outputFileURL, delegate);

    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];
    if (![mediaSource isMediaInjectionEnabled]) {
        NSLog(@"QAWolf:MovieFileOutput: No media injection, calling original start recording");
        [self event_startRecordingToOutputFileURL:outputFileURL recordingDelegate:delegate];
        return;
    }

    NSLog(@"QAWolf:MovieFileOutput: Media injection enabled, setting up writer");

    // Check if media source has video - for audio-only injection, skip video setup
    BOOL hasVideo = [mediaSource hasVideo];
    NSLog(@"QAWolf:MovieFileOutput: Media source has video: %@", hasVideo ? @"YES" : @"NO");

    // Store recording state
    RecordingState *state = [[RecordingState alloc] init];
    state.delegate = delegate;
    state.outputURL = outputFileURL;
    state.isActive = YES;
    state.startTime = CACurrentMediaTime();
    state.writerQueue = dispatch_queue_create("com.qawolf.moviefileoutput.writer", DISPATCH_QUEUE_SERIAL);
    self.recordingState = state;

    // Set up AVAssetWriter
    NSError *writerError;
    [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];

    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:outputFileURL
                                                      fileType:AVFileTypeQuickTimeMovie
                                                         error:&writerError];
    if (writerError) {
        NSLog(@"QAWolf:MovieFileOutput: Failed to create writer: %@", writerError);
        return;
    }

    // Only set up video input if media source has video
    AVAssetWriterInput *videoInput = nil;
    AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor = nil;

    if (hasVideo) {
        // Get video dimensions from MockMediaSource's current frame
        CVPixelBufferRef currentFrame = [mediaSource getLatestFrame];
        size_t width = 1920;
        size_t height = 1080;
        if (currentFrame) {
            width = CVPixelBufferGetWidth(currentFrame);
            height = CVPixelBufferGetHeight(currentFrame);
        }

        // Video settings
        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(width),
            AVVideoHeightKey: @(height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @6000000,
                AVVideoMaxKeyFrameIntervalKey: @30
            }
        };

        videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                        outputSettings:videoSettings];
        videoInput.expectsMediaDataInRealTime = YES;

        pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                        sourcePixelBufferAttributes:nil];

        [writer addInput:videoInput];
        NSLog(@"QAWolf:MovieFileOutput: Video input added to writer");
    } else {
        NSLog(@"QAWolf:MovieFileOutput: Skipping video input for audio-only injection");
    }

    // Audio settings - encode to AAC for efficient storage.
    // Use mic format (48kHz mono) if available since that's what the converter produces,
    // otherwise fall back to tap format.
    double audioSampleRate = 48000;
    int audioChannels = 1;
    if (mediaSource.targetAudioFormatReady) {
        audioSampleRate = mediaSource.targetAudioFormat.mSampleRate;
        audioChannels = mediaSource.targetAudioFormat.mChannelsPerFrame;
    } else if (mediaSource.audioTapFormatReady) {
        audioSampleRate = mediaSource.audioTapFormat.mSampleRate;
        audioChannels = mediaSource.audioTapFormat.mChannelsPerFrame;
    }
    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(audioSampleRate),
        AVNumberOfChannelsKey: @(audioChannels),
        AVEncoderBitRateKey: @128000
    };
    AVAssetWriterInput *audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                        outputSettings:audioSettings];
    audioInput.expectsMediaDataInRealTime = YES;

    [writer addInput:audioInput];

    // Store writer and inputs in state
    state.writer = writer;
    state.videoInput = videoInput;
    state.audioInput = audioInput;
    state.pixelBufferAdaptor = pixelBufferAdaptor;

    // Register as delegate to receive frames from MockMediaSource
    // Only register video delegate if media has video
    if (hasVideo) {
        [mediaSource registerVideoDelegate:self];
        NSLog(@"QAWolf:MovieFileOutput: Registered as video delegate");
    }

    // Register for audio only if the media source has audio tracks
    // For image-only injection, we want to record from the real microphone
    BOOL hasAudio = [mediaSource hasAudio];
    if (hasAudio) {
        // Register for audio — format is determined by the converter (mic format)
        [mediaSource registerAudioDelegate:self
                                    output:(AVCaptureAudioDataOutput *)self
                             audioSettings:nil
                             callbackQueue:nil];
        NSLog(@"QAWolf:MovieFileOutput: Registered for audio injection");
    } else {
        NSLog(@"QAWolf:MovieFileOutput: Image-only injection - will use real microphone");
    }

    // Start media playback now that recording has begun
    [mediaSource startMediaPlayback];
    NSLog(@"QAWolf:MovieFileOutput: Media playback started for recording");

    // For audio-only injection, start writer session immediately since no video frame will arrive
    if (!hasVideo) {
        NSLog(@"QAWolf:MovieFileOutput: Audio-only mode - starting writer session immediately");
        dispatch_async(state.writerQueue, ^{
            [state.writer startWriting];
            [state.writer startSessionAtSourceTime:kCMTimeZero];
            state.writerReady = YES;
            NSLog(@"QAWolf:MovieFileOutput: Writer session started for audio-only recording");
        });
    }

    // Call start delegate
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:)]) {
            NSArray<AVCaptureConnection *> *connections = [self.connections copy] ?: @[];
            void (*msgSend)(id, SEL, id, id, id) = (void*)objc_msgSend;
            msgSend(delegate, @selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:), self, outputFileURL, connections);
        }
    });

    NSLog(@"QAWolf:MovieFileOutput: Recording started, waiting for frames");
}

- (void)event_stopRecording {
    NSLog(@"QAWolf:MovieFileOutput: STOP RECORDING CALLED!");

    RecordingState *state = self.recordingState;
    if (!state || !state.isActive || !state.writer) {
        NSLog(@"QAWolf:MovieFileOutput: No active recording, calling original");
        [self event_stopRecording];
        return;
    }

    NSLog(@"QAWolf:MovieFileOutput: Finishing AVAssetWriter");

    // Mark inactive FIRST to prevent in-flight frames from being appended
    // after finishWriting is called
    state.isActive = NO;

    id<AVCaptureFileOutputRecordingDelegate> delegate = state.delegate;
    NSURL *outputURL = state.outputURL;
    AVAssetWriter *writer = state.writer;

    // Unregister delegate to stop receiving frames
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];
    // Only unregister video delegate if we have video (were registered)
    if (state.videoInput) {
        [mediaSource unregisterVideoDelegate:self];
    }
    [mediaSource registerAudioDelegate:nil output:(AVCaptureAudioDataOutput *)self audioSettings:nil callbackQueue:nil];

    // Stop and reset media playback to show placeholder
    [mediaSource stopMediaPlayback];

    // Clean up first frame if it wasn't appended
    if (state.firstFramePixelBuffer) {
        CVPixelBufferRelease(state.firstFramePixelBuffer);
        state.firstFramePixelBuffer = NULL;
    }

    // Clear recording state
    self.recordingState = nil;

    [writer finishWritingWithCompletionHandler:^{
        NSError *error = writer.status == AVAssetWriterStatusCompleted ? nil : writer.error;

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
                NSArray<AVCaptureConnection *> *connections = [self.connections copy] ?: @[];
                void (*msgSend)(id, SEL, id, id, id, id) = (void*)objc_msgSend;
                msgSend(delegate, @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:), self, outputURL, connections, error);
            }

            objc_setAssociatedObject(self, @selector(recordingDelegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, @selector(recordingOutputURL), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    }];

    NSLog(@"QAWolf:MovieFileOutput: Recording stopped");
}

- (BOOL)event_isRecording {
    NSLog(@"QAWolf:MovieFileOutput: IS RECORDING CALLED!");

    RecordingState *state = self.recordingState;
    MockMediaSource *mediaSource = [MockMediaSource sharedInstance];

    if ([mediaSource isMediaInjectionEnabled] && state && state.isActive) {
        NSLog(@"QAWolf:MovieFileOutput: Video injection active, returning YES for isRecording");
        return YES;
    }

    // Fall back to original implementation
    NSLog(@"QAWolf:MovieFileOutput: No video injection, calling original isRecording");
    return [self event_isRecording];
}

#pragma mark - Associated Object Properties

- (RecordingState *)recordingState {
    return objc_getAssociatedObject(self, @selector(recordingState));
}

- (void)setRecordingState:(RecordingState *)state {
    objc_setAssociatedObject(self, @selector(recordingState), state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - MockMediaSourceVideoDelegate

- (void)mockMediaSource:(id)source didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Forward to AVCaptureVideoDataOutputSampleBufferDelegate method
    AVCaptureConnection *connection = [(AVCaptureVideoDataOutput *)self connectionWithMediaType:AVMediaTypeVideo];
    [self captureOutput:(AVCaptureVideoDataOutput *)self
      didOutputSampleBuffer:sampleBuffer
             fromConnection:connection];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    RecordingState *state = self.recordingState;
    if (!state || !state.isActive || !state.writer) {
        return;
    }

    // Determine if this is video or audio based on sample buffer format
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(formatDesc);
    BOOL isVideo = (mediaType == kCMMediaType_Video);

    // Start writer session on first video frame (async to avoid blocking preview layer)
    if (!state.writerReady && isVideo && !state.firstFramePixelBuffer) {
        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

        NSLog(@"QAWolf:MovieFileOutput: Starting writer session at time %.3f", CMTimeGetSeconds(timestamp));

        // Save first frame to append after writer is ready
        if (pixelBuffer) {
            CVPixelBufferRetain(pixelBuffer);
            state.firstFramePixelBuffer = pixelBuffer;
            state.firstFrameTimestamp = timestamp;
        }

        // Start writer asynchronously on dedicated queue to avoid blocking frame delivery
        dispatch_async(state.writerQueue, ^{
            [state.writer startWriting];
            [state.writer startSessionAtSourceTime:timestamp];

            // Append the first frame immediately after starting the session
            if (state.firstFramePixelBuffer && state.videoInput.isReadyForMoreMediaData) {
                BOOL success = [state.pixelBufferAdaptor appendPixelBuffer:state.firstFramePixelBuffer
                                                     withPresentationTime:state.firstFrameTimestamp];
                if (success) {
                    NSLog(@"QAWolf:MovieFileOutput: Appended first frame at time %.3f", CMTimeGetSeconds(state.firstFrameTimestamp));
                } else {
                    NSLog(@"QAWolf:MovieFileOutput: ⚠️ Failed to append first frame: %@", state.writer.error);
                }
                CVPixelBufferRelease(state.firstFramePixelBuffer);
                state.firstFramePixelBuffer = NULL;
            }

            state.writerReady = YES;
            NSLog(@"QAWolf:MovieFileOutput: Writer session started successfully - ready for samples");
        });

        // Return early on first frame - will start appending on next frame once ready
        return;
    }

    // Skip samples until writer is ready
    if (!state.writerReady) {
        // Silently drop frames until writer is ready (happens briefly at start)
        return;
    }

    if (isVideo) {
        static dispatch_once_t videoOnceToken;
        dispatch_once(&videoOnceToken, ^{
            NSLog(@"QAWolf:MovieFileOutput: First video frame received");
        });

        if (!state.videoInput.isReadyForMoreMediaData) {
            NSLog(@"QAWolf:MovieFileOutput: ⚠️ Video input not ready for more data");
            return;
        }

        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

        if (pixelBuffer) {
            BOOL success = [state.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:timestamp];
            if (!success) {
                NSLog(@"QAWolf:MovieFileOutput: ⚠️ Failed to append video frame at time %.3f: %@",
                      CMTimeGetSeconds(timestamp), state.writer.error);
            }
        } else {
            NSLog(@"QAWolf:MovieFileOutput: ⚠️ No pixel buffer in video sample");
        }
    } else if (!isVideo) {
        // Audio sample
        static dispatch_once_t audioOnceToken;
        dispatch_once(&audioOnceToken, ^{
            NSLog(@"QAWolf:MovieFileOutput: First audio frame received");
        });

        if (!state.audioInput.isReadyForMoreMediaData) {
            return;
        }

        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

        // Log audio format on first audio sample
        static dispatch_once_t formatOnceToken;
        dispatch_once(&formatOnceToken, ^{
            CMFormatDescriptionRef audioFormat = CMSampleBufferGetFormatDescription(sampleBuffer);
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat);
            if (asbd) {
                NSLog(@"QAWolf:MovieFileOutput: Audio format - SampleRate: %.0f, Channels: %u, Format: %u, BitsPerChannel: %u",
                      asbd->mSampleRate, asbd->mChannelsPerFrame, asbd->mFormatID, asbd->mBitsPerChannel);
            }
        });

        BOOL success = [state.audioInput appendSampleBuffer:sampleBuffer];
        if (!success) {
            NSLog(@"QAWolf:MovieFileOutput: ⚠️ Failed to append audio sample: %@", state.writer.error);
        }
    }
}

@end
