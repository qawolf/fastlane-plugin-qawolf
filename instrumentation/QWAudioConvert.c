//
//  QWAudioConvert.c
//  instrumentation
//

#include "QWAudioConvert.h"
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

// Callback for AudioConverterFillComplexBuffer — feeds one pre-interleaved buffer, then
// reports end-of-data.
typedef struct {
    void *data;
    UInt32 size;
    UInt32 frames;
    bool consumed;
} QWConverterInputData;

static const OSStatus kQWConverterEndOfData = 'eod!';

static OSStatus qwConverterInputCallback(AudioConverterRef inConverter,
                                          UInt32 *ioNumberDataPackets,
                                          AudioBufferList *ioData,
                                          AudioStreamPacketDescription **outDataPacketDescription,
                                          void *inUserData) {
    QWConverterInputData *input = (QWConverterInputData *)inUserData;
    if (input->consumed || !input->data) {
        *ioNumberDataPackets = 0;
        return kQWConverterEndOfData;
    }
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = input->data;
    ioData->mBuffers[0].mDataByteSize = input->size;
    *ioNumberDataPackets = input->frames;
    input->consumed = true;
    return noErr;
}

bool QWAudioConvertBuffer(AudioConverterRef converter,
                           AudioBufferList *sourceBufferList,
                           const AudioStreamBasicDescription *sourceFormat,
                           UInt32 numberFrames,
                           const AudioStreamBasicDescription *destFormat,
                           AudioBufferList **outBufferList,
                           UInt32 *outFrames) {
    if (converter == NULL || sourceBufferList == NULL || sourceFormat == NULL ||
        destFormat == NULL || outBufferList == NULL || outFrames == NULL || numberFrames == 0) {
        return false;
    }

    // Step 1: interleave the source if it's non-interleaved (per-channel buffers) — the
    // AudioConverter input side needs one interleaved buffer. Zero-filled (calloc, not
    // malloc): if the source buffer list has fewer buffers than mChannelsPerFrame claims, or a
    // single source buffer's mDataByteSize is smaller than expected, some of interleavedSrc
    // would otherwise be left uninitialized and get fed to the converter as audio, producing
    // noise/garbage instead of silence for the missing portion.
    UInt32 srcChannels = sourceFormat->mChannelsPerFrame;
    UInt32 srcBytesPerSample = sourceFormat->mBitsPerChannel / 8;
    if (srcChannels == 0 || srcBytesPerSample == 0) return false;
    if (sourceFormat->mSampleRate <= 0 || destFormat->mSampleRate <= 0) return false; // guards the rateRatio divide below
    size_t interleavedSize = (size_t)numberFrames * srcChannels * srcBytesPerSample;
    void *interleavedSrc = calloc(1, interleavedSize);
    if (interleavedSrc == NULL) return false;

    if (sourceBufferList->mNumberBuffers > 1) {
        for (UInt32 f = 0; f < numberFrames; f++) {
            for (UInt32 ch = 0; ch < srcChannels && ch < sourceBufferList->mNumberBuffers; ch++) {
                void *src = sourceBufferList->mBuffers[ch].mData;
                if (src == NULL) { free(interleavedSrc); return false; }
                memcpy((uint8_t *)interleavedSrc + (f * srcChannels + ch) * srcBytesPerSample,
                       (uint8_t *)src + f * srcBytesPerSample, srcBytesPerSample);
            }
        }
    } else {
        void *src = sourceBufferList->mBuffers[0].mData;
        if (src == NULL) { free(interleavedSrc); return false; }
        size_t available = sourceBufferList->mBuffers[0].mDataByteSize;
        memcpy(interleavedSrc, src, interleavedSize < available ? interleavedSize : available);
    }

    // Step 2: shape the output AudioBufferList to match destFormat -- one buffer if
    // interleaved, one buffer per channel if not -- and let AudioConverterFillComplexBuffer
    // fill it directly (AudioConverter natively supports non-interleaved output; no manual
    // post-split needed).
    bool destNonInterleaved = (destFormat->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 destChannels = destFormat->mChannelsPerFrame > 0 ? destFormat->mChannelsPerFrame : 1;
    UInt32 numOutBuffers = destNonInterleaved ? destChannels : 1;

    double rateRatio = destFormat->mSampleRate / sourceFormat->mSampleRate;
    UInt32 outputFrames = (UInt32)(numberFrames * rateRatio) + 16;
    UInt32 perBufferBytes = outputFrames * destFormat->mBytesPerFrame;

    AudioBufferList *outList = (AudioBufferList *)malloc(offsetof(AudioBufferList, mBuffers) + numOutBuffers * sizeof(AudioBuffer));
    if (outList == NULL) { free(interleavedSrc); return false; }
    outList->mNumberBuffers = numOutBuffers;
    for (UInt32 i = 0; i < numOutBuffers; i++) {
        void *buf = calloc(1, perBufferBytes);
        if (buf == NULL) {
            for (UInt32 j = 0; j < i; j++) free(outList->mBuffers[j].mData);
            free(outList);
            free(interleavedSrc);
            return false;
        }
        outList->mBuffers[i].mNumberChannels = destNonInterleaved ? 1 : destChannels;
        outList->mBuffers[i].mDataByteSize = perBufferBytes;
        outList->mBuffers[i].mData = buf;
    }

    QWConverterInputData inputData = {
        .data = interleavedSrc,
        .size = (UInt32)interleavedSize,
        .frames = numberFrames,
        .consumed = false
    };

    OSStatus status = AudioConverterFillComplexBuffer(converter, qwConverterInputCallback, &inputData,
                                                        &outputFrames, outList, NULL);
    free(interleavedSrc);

    if (status != noErr && status != kQWConverterEndOfData) {
        for (UInt32 i = 0; i < numOutBuffers; i++) free(outList->mBuffers[i].mData);
        free(outList);
        return false;
    }

    *outBufferList = outList;
    *outFrames = outputFrames;
    return true;
}

void QWAudioConvertFreeBufferList(AudioBufferList *bufferList) {
    if (bufferList == NULL) return;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        free(bufferList->mBuffers[i].mData);
    }
    free(bufferList);
}
