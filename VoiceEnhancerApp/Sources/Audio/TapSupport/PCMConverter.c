#include "include/PCMConverter.h"
#include <CoreServices/CoreServices.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { VEBlockFrames = 1024, VEInputFrames = 128, VEInputEmpty = 'vemp' };
struct VEPCMConverter {
    AudioConverterRef audio;
    float output[VEBlockFrames];
    float input[VEInputFrames];
    UInt32 inputFrames;
};
typedef struct {
    const float *samples;
    UInt32 remaining;
} VEInput;

static OSStatus supplyInput(AudioConverterRef converter, UInt32 *packets,
                            AudioBufferList *data, AudioStreamPacketDescription **descriptions,
                            void *context) {
    VEInput *input = context;
    UInt32 count = input->remaining < VEBlockFrames ? input->remaining : VEBlockFrames;
    *packets = count;
    data->mNumberBuffers = 1;
    data->mBuffers[0] = (AudioBuffer){1, count * sizeof(float), (void *)input->samples};
    input->samples += count;
    input->remaining -= count;
    // Zero + noErr means EOF and flushes the resampler. This is only a buffer
    // boundary: Apple's streaming contract uses a custom error to suspend.
    return count ? noErr : VEInputEmpty;
}

OSStatus VEPCMConverterProcess(VEPCMConverter *converter, const float *input, UInt32 frames,
                               VEPCMOutputCallback output, void *context) {
    if (!converter || !input || !output) return paramErr;
    if (frames == 0) return noErr;
    if (!converter->audio) {
        while (frames) {
            UInt32 count = frames < VEBlockFrames ? frames : VEBlockFrames;
            memcpy(converter->output, input, count * sizeof(float));
            output(context, converter->output, count);
            input += count;
            frames -= count;
        }
        return noErr;
    }
    // Feed fixed native slices so AudioConverter's lookahead is independent
    // of tap boundaries. Retain the partial slice across taps (at most 16 ms
    // at 8 kHz, 2.7 ms at 48 kHz). Input storage stays owned by the converter.
    while (frames) {
        UInt32 count = VEInputFrames - converter->inputFrames;
        if (count > frames) count = frames;
        memcpy(converter->input + converter->inputFrames, input, count * sizeof(float));
        converter->inputFrames += count;
        input += count;
        frames -= count;
        if (converter->inputFrames < VEInputFrames) continue;
        VEInput source = {converter->input, VEInputFrames};
        for (;;) {
            UInt32 count = VEBlockFrames;
            AudioBufferList destination = {1, {{1, sizeof(converter->output), converter->output}}};
            OSStatus status = AudioConverterFillComplexBuffer(converter->audio, supplyInput, &source,
                                                              &count, &destination, NULL);
            if (status != noErr && status != VEInputEmpty) return status;
            if (count) output(context, converter->output, count);
            if (status == VEInputEmpty) break;
        }
        converter->inputFrames = 0;
    }
    return noErr;
}

static void discardOutput(void *context, float *samples, UInt32 frames) {}

VEPCMConverter *VEPCMConverterCreate(double inputRate, OSStatus *error) {
    *error = paramErr;
    if (!isfinite(inputRate) || inputRate < 8000 || inputRate > 384000) return NULL;
    VEPCMConverter *converter = calloc(1, sizeof(*converter));
    if (!converter) { *error = memFullErr; return NULL; }
    *error = noErr;
    if (inputRate == 48000) return converter;
    AudioStreamBasicDescription source = {
        inputRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked,
        sizeof(float), 1, sizeof(float), 1, 32, 0
    };
    AudioStreamBasicDescription destination = source;
    destination.mSampleRate = 48000;
    *error = AudioConverterNew(&source, &destination, &converter->audio);
    if (*error == noErr) {
        UInt32 quality = kAudioConverterQuality_High;
        *error = AudioConverterSetProperty(converter->audio, kAudioConverterSampleRateConverterQuality,
                                           sizeof(quality), &quality);
    }
    // Exercise the maximum input/output slice before entering the tap. Buffer
    // sizes stay fixed thereafter; no per-tap converter or buffer creation.
    if (*error == noErr) {
        float silence[VEBlockFrames * 4] = {0};
        *error = VEPCMConverterProcess(converter, silence, VEBlockFrames * 4, discardOutput, NULL);
        if (*error == noErr) *error = AudioConverterReset(converter->audio);
    }
    if (*error != noErr) { VEPCMConverterDestroy(converter); return NULL; }
    return converter;
}

void VEPCMConverterDestroy(VEPCMConverter *converter) {
    if (!converter) return;
    if (converter->audio) AudioConverterDispose(converter->audio);
    free(converter);
}
