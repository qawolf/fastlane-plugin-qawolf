//
//  QWAudioConvert.h
//  instrumentation
//
//  Shared "interleave a source AudioBufferList, then run it through an AudioConverter" helper.
//  Used by both MockMediaSource's audio tap (converting injected media to whatever format an
//  AVCaptureAudioDataOutput/AVAudioRecorder consumer requested) and QWAudioUnitBridge
//  (converting the same source audio to a WebRTC mic-capture Audio Unit's format) — previously
//  each had its own near-identical copy of this logic.
//

#ifndef QWAudioConvert_h
#define QWAudioConvert_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Converts `numberFrames` frames of PCM in `sourceBufferList` (format `sourceFormat`, which
// may be interleaved or non-interleaved/multi-buffer) through `converter` (must already be
// built for sourceFormat -> destFormat) into a freshly allocated AudioBufferList shaped to
// match `destFormat`: one buffer if destFormat is interleaved, one buffer per channel if
// destFormat is non-interleaved. On success, returns true, sets *outBufferList to the
// allocated list (free with QWAudioConvertFreeBufferList) and *outFrames to the number of
// frames actually produced. Returns false (nothing to free) on failure.
//
// Not realtime-safe (mallocs) — call only from non-realtime threads. Both current call sites
// (MockMediaSource's MTAudioProcessingTap callback and QWAudioUnitBridge's tap-fed push) run
// on a background/non-realtime-ish audio processing thread, not the hardware I/O render
// thread, matching the rest of this codebase's existing practice in that same tap callback.
bool QWAudioConvertBuffer(AudioConverterRef converter,
                           AudioBufferList *sourceBufferList,
                           const AudioStreamBasicDescription *sourceFormat,
                           UInt32 numberFrames,
                           const AudioStreamBasicDescription *destFormat,
                           AudioBufferList **outBufferList,
                           UInt32 *outFrames);

// Frees an AudioBufferList produced by QWAudioConvertBuffer (each buffer's mData, then the
// list itself).
void QWAudioConvertFreeBufferList(AudioBufferList *bufferList);

#ifdef __cplusplus
}
#endif

#endif /* QWAudioConvert_h */
