#import "include/CaptureGraph.h"
#include <math.h>

NSError *VEConfigureCaptureGraphSafely(AVAudioEngine *engine,
                                      AVAudioNode *source,
                                      AVAudioMixerNode *captureMixer,
                                      AVAudioFormat *nativeFormat,
                                      AVAudioFormat *captureFormat) {
    if (!isfinite(nativeFormat.sampleRate) || nativeFormat.sampleRate <= 0 ||
        nativeFormat.channelCount == 0 || captureFormat.sampleRate != 48000 ||
        captureFormat.channelCount != nativeFormat.channelCount ||
        captureFormat.commonFormat != AVAudioPCMFormatFloat32 || captureFormat.isInterleaved) {
        return [NSError errorWithDomain:@"tech.aheadly.voice-enhancer.capture-graph"
                                  code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"Unsupported microphone capture format."}];
    }

    @try {
        [engine attachNode:captureMixer];
        [engine connect:source to:captureMixer format:nativeFormat];
        [engine connect:captureMixer to:engine.mainMixerNode format:captureFormat];
        captureMixer.outputVolume = 1;
        engine.mainMixerNode.outputVolume = 0;
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"tech.aheadly.voice-enhancer.capture-graph"
                                  code:2
                              userInfo:@{
            NSLocalizedDescriptionKey: exception.reason ?: @"Could not configure microphone capture.",
            @"exceptionName": exception.name
        }];
    }
}
