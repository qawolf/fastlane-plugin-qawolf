//
//  AVCaptureMovieFileOutputInjector.h
//  ios-agent
//
//  Created by Andreas Lüdeke on 22.01.25.
//

#ifndef AVCaptureMovieFileOutputInjector_h
#define AVCaptureMovieFileOutputInjector_h

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Movie file output swizzling
@interface AVCaptureMovieFileOutput (EventDrivenVideoInjection)
- (void)event_startRecordingToOutputFileURL:(NSURL *)outputFileURL
                          recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate;
- (void)event_stopRecording;
- (BOOL)event_isRecording;

// Associated object getters
- (id<AVCaptureFileOutputRecordingDelegate>)recordingDelegate;
- (NSURL *)recordingOutputURL;
@end

// Declare delegate protocol methods to avoid compiler warnings
@interface NSObject (AVCaptureFileOutputRecordingDelegateMethods)
- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections;
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error;
@end

#endif /* AVCaptureMovieFileOutputInjector_h */