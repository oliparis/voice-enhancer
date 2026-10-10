#ifndef VOICE_ENHANCER_CAPTURE_GRAPH_H
#define VOICE_ENHANCER_CAPTURE_GRAPH_H

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Connect an already-attached source in its native format to a conversion
// mixer. Tap the mixer's output, not the hardware input. Preserve the channel
// count so the caller can take channel 0 without stereo downmixing.
// The downstream main mixer is muted to avoid microphone feedback.
// Graph setup only; no conversion work is performed in the caller's callback.
NSError * _Nullable VEConfigureCaptureGraphSafely(AVAudioEngine *engine,
                                                AVAudioNode *source,
                                                AVAudioMixerNode *captureMixer,
                                                AVAudioFormat *nativeFormat,
                                                AVAudioFormat *captureFormat);

NS_ASSUME_NONNULL_END

#endif // VOICE_ENHANCER_CAPTURE_GRAPH_H
