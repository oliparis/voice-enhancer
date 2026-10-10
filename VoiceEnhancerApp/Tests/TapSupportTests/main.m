#import <AVFoundation/AVFoundation.h>
#import "AVAudioTapInstaller.h"
#import "CaptureGraph.h"
#include <math.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>

// Throw in Objective-C so no Swift frame is unwound by NSException.
// No hardware engine or microphone permission is needed by this double.
@interface VETestTapNode : AVAudioMixerNode
@property(nonatomic) BOOL failInstall;
@property(nonatomic) BOOL failRemove;
@property(nonatomic) BOOL partiallyInstall;
@property(nonatomic) BOOL omitReason;
@property(nonatomic) BOOL installed;
@property(nonatomic) AVAudioNodeBus lastBus;
@property(nonatomic) AVAudioFrameCount lastBufferSize;
@property(nonatomic, strong) AVAudioFormat *lastFormat;
@property(nonatomic, copy) AVAudioNodeTapBlock lastBlock;
@end

@implementation VETestTapNode
- (void)installTapOnBus:(AVAudioNodeBus)bus
            bufferSize:(AVAudioFrameCount)bufferSize
                format:(AVAudioFormat *)format
                 block:(AVAudioNodeTapBlock)block {
    self.lastBus = bus;
    self.lastBufferSize = bufferSize;
    self.lastFormat = format;
    self.lastBlock = block;
    if (self.failInstall) {
        self.installed = self.partiallyInstall;
        @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                      reason:self.omitReason ? nil : @"format mismatch"
                                    userInfo:nil];
    }
    if (self.installed) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                      reason:@"duplicate tap"
                                    userInfo:nil];
    }
    self.installed = YES;
}
- (void)removeTapOnBus:(AVAudioNodeBus)bus {
    self.lastBus = bus;
    if (self.failRemove) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                      reason:@"removal failed"
                                    userInfo:nil];
    }
    self.installed = NO;
    self.lastBlock = nil;
}
@end

@interface VETapProbe : NSObject {
@public
    atomic_uint_fast64_t frames;
    atomic_uint_fast64_t energy;
    atomic_bool invalidFormat;
}
@end
@implementation VETapProbe
- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&frames, 0);
        atomic_init(&energy, 0);
        atomic_init(&invalidFormat, false);
    }
    return self;
}
@end

static int failures = 0;
static int checks = 0;
static void expect(BOOL condition, const char *description) {
    ++checks;
    if (!condition) {
        ++failures;
        fprintf(stderr, "FAIL: %s\n", description);
    }
}

// Render the production conversion graph with a player instead of hardware.
// Unmute its downstream mixer only while inspecting converted samples; the
// separate muted pass verifies that production setup does not monitor input.
static NSData *renderCapture(double sourceRate, AVAudioChannelCount channels,
                             BOOL irregularBlocks, double frequency, BOOL muted) {
    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioPlayerNode *player = [AVAudioPlayerNode new];
    AVAudioMixerNode *captureMixer = [AVAudioMixerNode new];
    [engine attachNode:player];
    AVAudioFormat *native = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sourceRate channels:channels];
    AVAudioFormat *converted = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:channels];
    NSError *error = VEConfigureCaptureGraphSafely(engine, player, captureMixer, native, converted);
    expect(error == nil, "conversion graph accepts native format");
    if (error) {
        fprintf(stderr, "Graph error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    expect(engine.mainMixerNode.outputVolume == 0, "capture graph is muted downstream");
    expect(captureMixer.outputVolume == 1, "capture mixer preserves input level");
    AVAudioFormat *actual = [captureMixer outputFormatForBus:0];
    expect(actual.sampleRate == 48000 && actual.channelCount == channels,
           "capture output is 48 kHz with original channel count");
    // Check tap installation on the converted bus, where formats must match.
    VETapProbe *probe = [VETapProbe new];
    error = VEInstallInputTapSafely(captureMixer, 0, 512, converted,
                                  ^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        if (buffer.format.sampleRate != 48000 || buffer.format.channelCount != channels) {
            atomic_store(&probe->invalidFormat, true);
        }
        double sum = 0;
        for (AVAudioFrameCount i = 0; i < buffer.frameLength; ++i) {
            double sample = buffer.floatChannelData[0][i];
            sum += sample * sample;
        }
        atomic_fetch_add(&probe->energy, (uint_fast64_t)(sum * 1e9));
        atomic_fetch_add(&probe->frames, buffer.frameLength);
    });
    expect(error == nil, "converted mixer tap installs without format mismatch");
    engine.mainMixerNode.outputVolume = muted ? 0 : 1;
    if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                   format:converted maximumFrameCount:4096 error:&error]) {
        expect(NO, "manual rendering setup succeeds");
        fprintf(stderr, "Manual error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:native
                                                         frameCapacity:(AVAudioFrameCount)(sourceRate * 2)];
    input.frameLength = input.frameCapacity;
    for (AVAudioChannelCount channel = 0; channel < channels; ++channel) {
        for (AVAudioFrameCount i = 0; i < input.frameLength; ++i) {
            double hz = channel == 0 ? frequency : 2000;
            double amplitude = channel == 0 ? 0.25 : 0.5;
            input.floatChannelData[channel][i] = (float)(amplitude * sin(2 * M_PI * hz * i / sourceRate));
        }
    }
    [player scheduleBuffer:input completionHandler:nil];
    if (![engine startAndReturnError:&error]) {
        expect(NO, "offline engine starts");
        return nil;
    }
    [player play];
    const AVAudioFrameCount frames = 24000;
    NSMutableData *result = [NSMutableData dataWithLength:frames * channels * sizeof(float)];
    float *samples = result.mutableBytes;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:converted frameCapacity:4096];
    AVAudioFrameCount position = 0;
    const AVAudioFrameCount sizes[] = {113, 509, 2048, 37};
    unsigned block = 0;
    while (position < frames) {
        AVAudioFrameCount requested = irregularBlocks ? sizes[(block++) % 4] : 4096;
        requested = MIN(requested, frames - position);
        AVAudioEngineManualRenderingStatus status = [engine renderOffline:requested toBuffer:output error:&error];
        if (status != AVAudioEngineManualRenderingStatusSuccess || output.frameLength != requested) {
            expect(NO, "offline rendering supplies every requested frame");
            fprintf(stderr, "Render status: %ld, error: %s\n", (long)status,
                    error ? error.localizedDescription.UTF8String : "none");
            [engine stop];
            return nil;
        }
        for (AVAudioChannelCount channel = 0; channel < channels; ++channel) {
            memcpy(samples + channel * frames + position, output.floatChannelData[channel],
                   requested * sizeof(float));
        }
        position += requested;
    }
    if (muted) {
        // Taps are delivered asynchronously. Wait outside the render block.
        for (unsigned attempt = 0; attempt < 1000 && atomic_load(&probe->frames) < frames / 2; ++attempt) {
            usleep(1000);
        }
        expect(atomic_load(&probe->frames) >= frames / 2,
               "muted playback still delivers captured frames");
        expect(atomic_load(&probe->energy) > 1000000,
               "muted playback does not mute the capture tap");
        expect(!atomic_load(&probe->invalidFormat), "tap buffers use the converted format");
    }
    [engine stop];
    expect(VERemoveInputTapSafely(captureMixer, 0) == nil, "converted mixer tap removes");
    expect(position == frames, "converted output has exact requested duration");
    return result;
}

static double rms(const float *samples, unsigned count) {
    double sum = 0;
    for (unsigned i = 0; i < count; ++i) sum += (double)samples[i] * samples[i];
    return sqrt(sum / count);
}

static void testNativeConversion(void) {
    AVAudioEngine *invalidEngine = [AVAudioEngine new];
    AVAudioPlayerNode *invalidSource = [AVAudioPlayerNode new];
    AVAudioMixerNode *invalidMixer = [AVAudioMixerNode new];
    AVAudioFormat *stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AVAudioFormat *mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    expect(VEConfigureCaptureGraphSafely(invalidEngine, invalidSource, invalidMixer, stereo, mono) != nil,
           "channel-changing configuration is rejected before graph mutation");
    expect(![invalidEngine.attachedNodes containsObject:invalidMixer], "invalid graph stays unmodified");
    const double rates[] = {8000, 16000, 44100, 48000, 96000};
    for (unsigned rateIndex = 0; rateIndex < 5; ++rateIndex) {
        for (AVAudioChannelCount channels = 1; channels <= 2; ++channels) {
            NSData *regular = renderCapture(rates[rateIndex], channels, NO, 1000, NO);
            NSData *irregular = renderCapture(rates[rateIndex], channels, YES, 1000, NO);
            if (!regular || !irregular) continue;
            const float *a = regular.bytes;
            const float *b = irregular.bytes;
            double maximumDifference = 0;
            BOOL finite = YES;
            for (unsigned i = 0; i < 24000 * channels; ++i) {
                finite = finite && isfinite(a[i]) && isfinite(b[i]);
                maximumDifference = fmax(maximumDifference, fabs((double)a[i] - b[i]));
            }
            expect(finite, "converted samples are finite");
            expect(maximumDifference < 0.001, "conversion is independent of render block boundaries");
            expect(fabs(rms(a + 4096, 19904) - 0.25 / sqrt(2)) < 0.003,
                   "first channel level survives conversion");
            if (channels == 2) {
                expect(fabs(rms(a + 24000 + 4096, 19904) - 0.5 / sqrt(2)) < 0.003,
                       "second channel remains separate rather than mixing into first");
            }
        }
    }
    NSData *muted = renderCapture(44100, 2, NO, 1000, YES);
    if (muted) expect(rms(muted.bytes, 48000) < 1e-6, "production playback path stays silent");
    NSData *rejected = renderCapture(96000, 1, NO, 30000, NO);
    if (rejected) expect(rms((const float *)rejected.bytes + 4096, 19904) < 0.01,
                         "downsampling suppresses above-Nyquist input");
}

int main(void) {
    @autoreleasepool {
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
        __block BOOL callbackRan = NO;
        AVAudioNodeTapBlock block = ^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            callbackRan = YES;
        };
        VETestTapNode *node = [VETestTapNode new];
        expect(VEInstallInputTapSafely(node, 3, 512, format, block) == nil, "successful install returns nil");
        expect(node.installed && node.lastBus == 3 && node.lastBufferSize == 512,
               "install forwards bus and buffer size");
        expect(node.lastFormat == format, "install forwards format unchanged");
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:1];
        node.lastBlock(buffer, [AVAudioTime timeWithSampleTime:0 atRate:48000]);
        expect(callbackRan, "install forwards callback");
        expect(VERemoveInputTapSafely(node, 3) == nil && !node.installed,
               "successful removal clears tap");

        node.failInstall = YES;
        NSError *error = VEInstallInputTapSafely(node, 0, 512, format, block);
        expect(error != nil && [error.domain isEqualToString:@"tech.aheadly.voice-enhancer.avaudio-tap"],
               "installation exception becomes NSError");
        expect([error.localizedDescription isEqualToString:@"format mismatch"], "exception reason retained");
        expect([error.userInfo[@"exceptionName"] isEqualToString:NSInternalInconsistencyException],
               "exception name retained");
        node.omitReason = YES;
        error = VEInstallInputTapSafely(node, 0, 512, format, block);
        expect([error.localizedDescription isEqualToString:@"Audio tap operation failed."],
               "missing exception reason has fallback");

        node.partiallyInstall = YES;
        expect(VEInstallInputTapSafely(node, 0, 512, format, block) != nil && node.installed,
               "partial install still reports failure");
        expect(VERemoveInputTapSafely(node, 0) == nil && !node.installed,
               "failed partial installation can be cleaned up");
        node.failInstall = NO;
        expect(VEInstallInputTapSafely(node, 0, 512, format, block) == nil,
               "install succeeds after failed attempt and cleanup");
        expect(VEInstallInputTapSafely(node, 0, 512, format, block) != nil,
               "duplicate installation becomes an error instead of aborting");
        node.failRemove = YES;
        error = VERemoveInputTapSafely(node, 0);
        expect(error != nil && [error.localizedDescription isEqualToString:@"removal failed"],
               "removal exception becomes NSError");
        node.failRemove = NO;
        expect(VERemoveInputTapSafely(node, 0) == nil, "later removal succeeds");
        VETestTapNode *replacement = [VETestTapNode new];
        expect(VEInstallInputTapSafely(replacement, 0, 512, format, block) == nil,
               "fresh node can install after prior graph failure");
        expect(VERemoveInputTapSafely(replacement, 0) == nil, "replacement tap cleans up");
        testNativeConversion();
        printf("Tap support: %d checks, %d failures\n", checks, failures);
    }
    return failures ? 1 : 0;
}
