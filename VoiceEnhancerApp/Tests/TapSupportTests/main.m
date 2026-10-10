#import <AVFoundation/AVFoundation.h>
#import "AVAudioTapInstaller.h"
#import "PCMConverter.h"
#import <CoreAudio/CoreAudio.h>
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

static int failures = 0;
static int checks = 0;
static void expect(BOOL condition, const char *description) {
    ++checks;
    if (!condition) {
        ++failures;
        fprintf(stderr, "FAIL: %s\n", description);
    }
}

// Append output only in tests; production writes directly into the DSP/ring.
static void collectOutput(void *context, float *samples, UInt32 frames) {
    NSMutableData *data = (__bridge NSMutableData *)context;
    [data appendBytes:samples length:frames * sizeof(float)];
}

static NSData *convertSignal(double rate, BOOL irregular, double frequency, unsigned seconds) {
    OSStatus error = noErr;
    VEPCMConverter *converter = VEPCMConverterCreate(rate, &error);
    expect(converter != NULL && error == noErr, "converter initializes");
    if (!converter) return nil;
    unsigned frames = (unsigned)(rate * seconds);
    NSMutableData *source = [NSMutableData dataWithLength:frames * sizeof(float)];
    float *samples = source.mutableBytes;
    for (unsigned i = 0; i < frames; ++i) samples[i] = 0.25 * sin(2 * M_PI * frequency * i / rate);
    NSMutableData *result = [NSMutableData data];
    const unsigned sizes[] = {1, 113, 509, 4800, 37, 32768};
    BOOL succeeded = YES;
    for (unsigned offset = 0, block = 0; offset < frames; ++block) {
        unsigned count = irregular ? sizes[block % 6] : 512;
        count = MIN(count, frames - offset);
        error = VEPCMConverterProcess(converter, samples + offset, count, collectOutput, (__bridge void *)result);
        if (error != noErr) { succeeded = NO; break; }
        offset += count;
    }
    expect(succeeded, "all native input blocks convert without error");
    VEPCMConverterDestroy(converter);
    return result;
}

static double rms(const float *samples, unsigned count) {
    double energy = 0;
    for (unsigned i = 0; i < count; ++i) energy += samples[i] * samples[i];
    return sqrt(energy / count);
}

static void mutateOutput(void *context, float *samples, UInt32 frames) {
    *(UInt32 *)context += frames;
    memset(samples, 0, frames * sizeof(float));
}

static void testNativeConversion(void) {
    const double rates[] = {8000, 16000, 44100, 48000, 96000, 192000};
    for (unsigned rate = 0; rate < 6; ++rate) {
        NSData *regular = convertSignal(rates[rate], NO, 1000, 2);
        NSData *irregular = convertSignal(rates[rate], YES, 1000, 2);
        if (!regular || !irregular) continue;
        fprintf(stderr, "rate %.0f regular %lu irregular %lu\n", rates[rate], regular.length / sizeof(float), irregular.length / sizeof(float));
        expect(regular.length == irregular.length, "output duration does not depend on input chunking");
        unsigned frames = (unsigned)MIN(regular.length, irregular.length) / sizeof(float);
        // A continuous stream keeps a small filter tail pending until future
        // input arrives; it must not lose duration at each tap boundary.
        expect(frames > 95000 && frames <= 96000, "two seconds preserved apart from bounded filter latency");
        const float *a = regular.bytes, *b = irregular.bytes;
        double difference = 0;
        BOOL finite = YES;
        for (unsigned i = 0; i < frames; ++i) {
            finite = finite && isfinite(a[i]) && isfinite(b[i]);
            difference = fmax(difference, fabs((double)a[i] - b[i]));
        }
        expect(finite, "conversion produces finite samples");
        expect(difference < 0.00001, "phase and filter history survive arbitrary tap boundaries");
        if (frames > 4096) expect(fabs(rms(a + 4096, frames - 4096) - 0.25 / sqrt(2)) < 0.003,
                                  "voice-band signal level survives conversion");
    }
    NSData *rejected = convertSignal(96000, YES, 30000, 2);
    if (rejected.length > 4096 * sizeof(float)) {
        expect(rms((const float *)rejected.bytes + 4096, (unsigned)rejected.length / sizeof(float) - 4096) < 0.01,
               "downsampling rejects above-Nyquist input");
    }
    NSData *longStream = convertSignal(44100, YES, 1000, 30);
    expect(longStream.length / sizeof(float) > 30 * 48000 - 1000 &&
           longStream.length / sizeof(float) <= 30 * 48000,
           "fractional rate conversion does not accumulate duration loss");
    OSStatus error;
    expect(VEPCMConverterCreate(0, &error) == NULL && error != noErr, "invalid rate rejected");
    expect(VEPCMConverterCreate(NAN, &error) == NULL && error != noErr, "NaN rate rejected");
    VEPCMConverter *converter = VEPCMConverterCreate(48000, &error);
    float input[32768];
    for (unsigned i = 0; i < 32768; ++i) input[i] = 0.25f;
    UInt32 count = 0;
    expect(VEPCMConverterProcess(converter, input, 32768, mutateOutput, &count) == noErr && count == 32768,
           "oversized taps split into bounded DSP blocks without truncation");
    expect(input[0] == 0.25f && input[32767] == 0.25f, "DSP mutations cannot overwrite the input tap");
    expect(VEPCMConverterProcess(converter, input, 0, mutateOutput, &count) == noErr && count == 32768,
           "empty input produces no duplicate output");
    VEPCMConverterDestroy(converter);
}

// Opt-in hardware smoke test. Counts frames only; never saves or plays audio.
typedef struct {
    atomic_uint_fast64_t nativeFrames;
    atomic_uint_fast64_t convertedFrames;
    atomic_int error;
} VELiveProbe;
static void countLiveOutput(void *context, float *samples, UInt32 frames) {
    VELiveProbe *probe = context;
    atomic_fetch_add(&probe->convertedFrames, frames);
}
static int testLiveInput(AudioDeviceID device) {
    AVAudioEngine *engine = [AVAudioEngine new];
    OSStatus status = AudioUnitSetProperty(engine.inputNode.audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, sizeof(device));
    expect(status == noErr, "bind live input device");
    AVAudioFormat *native = [engine.inputNode inputFormatForBus:0];
    fprintf(stderr, "Live input %u: %.0f Hz, %u channels\n", device, native.sampleRate, native.channelCount);
    VEPCMConverter *converter = VEPCMConverterCreate(native.sampleRate, &status);
    if (!converter || !native.channelCount) { expect(NO, "valid live input format"); return 1; }
    VELiveProbe probe;
    atomic_init(&probe.nativeFrames, 0);
    atomic_init(&probe.convertedFrames, 0);
    atomic_init(&probe.error, 0);
    VELiveProbe *p = &probe;
    NSError *error = VEInstallInputTapSafely(engine.inputNode, 0, 512, native, ^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
        atomic_fetch_add(&p->nativeFrames, buffer.frameLength);
        OSStatus result = VEPCMConverterProcess(converter, buffer.floatChannelData[0], buffer.frameLength, countLiveOutput, p);
        if (result) atomic_store(&p->error, result);
    });
    expect(error == nil, "install native hardware tap");
    BOOL started = error == nil && [engine startAndReturnError:&error];
    expect(started, "input-only engine starts on physical device");
    if (error) fprintf(stderr, "%s\n", error.description.UTF8String);
    if (started) usleep(2000000);
    [engine stop];
    VERemoveInputTapSafely(engine.inputNode, 0);
    // Tap removal joins callbacks before the converter/probe are released.
    uint64_t source = atomic_load(&probe.nativeFrames), converted = atomic_load(&probe.convertedFrames);
    fprintf(stderr, "Native frames: %llu; converted frames: %llu; conversion error: %d\n",
            source, converted, atomic_load(&probe.error));
    expect(source > native.sampleRate, "physical microphone supplies sustained input");
    expect(converted > 48000 && fabs(converted - source * 48000.0 / native.sampleRate) < 1000,
           "live output duration matches native stream at 48 kHz");
    expect(atomic_load(&probe.error) == noErr, "live conversion has no errors");
    VEPCMConverterDestroy(converter);
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--live-input") == 0) {
            return testLiveInput((AudioDeviceID)strtoul(argv[2], NULL, 10));
        }
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
