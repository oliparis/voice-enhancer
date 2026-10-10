#ifndef VOICE_ENHANCER_PCM_CONVERTER_H
#define VOICE_ENHANCER_PCM_CONVERTER_H

#include <AudioToolbox/AudioToolbox.h>

// A single-stream, mono float32 converter. Create/destroy off the audio thread.
// Process serially; input is channel 0 of the native noninterleaved tap buffer.
// Output is mutable scratch storage, valid only for the duration of the callback.
// Temporary input starvation preserves filter/phase history between calls.
// No application allocations, locks, logging or dispatch in Process.
typedef struct VEPCMConverter VEPCMConverter;
typedef void (*VEPCMOutputCallback)(void *context, float *samples, UInt32 frames);
VEPCMConverter *VEPCMConverterCreate(double inputRate, OSStatus *error);
void VEPCMConverterDestroy(VEPCMConverter *converter);
OSStatus VEPCMConverterProcess(VEPCMConverter *converter, const float *input, UInt32 frames,
                               VEPCMOutputCallback output, void *context);

#endif
