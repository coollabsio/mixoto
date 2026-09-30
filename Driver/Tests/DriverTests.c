#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../Loopback.h"

static AudioServerPlugInDriverRef driver;
static CFPropertyListRef stored = NULL;
static UInt32 nameChanges = 0;
static OSStatus storage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *data) {
    (void)host; (void)key; *data = stored ? CFRetain(stored) : NULL; return 0;
}
static OSStatus writeStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef data) {
    (void)host; assert(CFEqual(key, CFSTR("device name")));
    if (stored) { CFRelease(stored); }
    stored = CFRetain(data); return 0;
}
static OSStatus changed(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    (void)host; (void)object;
    if (count == 1 && addresses[0].mSelector == kAudioObjectPropertyName) { ++nameChanges; }
    return 0;
}
static AudioObjectPropertyAddress address(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){ selector, scope, kAudioObjectPropertyElementMain };
}
static UInt32 property(AudioObjectID object, UInt32 selector, UInt32 scope, void *data, UInt32 capacity) {
    AudioObjectPropertyAddress prop = address(selector, scope);
    UInt32 size = 0;
    assert((*driver)->HasProperty(driver, object, getpid(), &prop));
    assert((*driver)->GetPropertyData(driver, object, getpid(), &prop, 0, NULL, capacity, &size, data) == 0);
    return size;
}
static UInt32 scalar(AudioObjectID object, UInt32 selector, UInt32 scope) {
    UInt32 data = UINT32_MAX;
    assert(property(object, selector, scope, &data, sizeof(data)) == sizeof(data));
    return data;
}
static void silence(const float *data, size_t count) {
    for (size_t i = 0; i < count; ++i) { assert(data[i] == 0); }
}
static void little16(FILE *file, uint16_t value) {
    unsigned char bytes[] = { value & 255, value >> 8 };
    assert(fwrite(bytes, 1, sizeof(bytes), file) == sizeof(bytes));
}
static void little32(FILE *file, uint32_t value) {
    little16(file, value & 65535); little16(file, value >> 16);
}
static void recordOfflineProbe(const char *path, AudioObjectID device, AudioObjectID input, AudioObjectID output) {
    FILE *file = fopen(path, "wb"); assert(file);
    const UInt32 total = ((7 * MX_RATE + MX_PERIOD - 1) / MX_PERIOD) * MX_PERIOD;
    assert(fwrite("RIFF", 1, 4, file) == 4); little32(file, 36 + total * 4);
    assert(fwrite("WAVEfmt ", 1, 8, file) == 8); little32(file, 16);
    little16(file, 1); little16(file, 2); little32(file, MX_RATE); little32(file, MX_RATE * 4);
    little16(file, 4); little16(file, 16); assert(fwrite("data", 1, 4, file) == 4); little32(file, total * 4);
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mFlags = cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
    float source[MX_PERIOD * 2], returned[MX_PERIOD * 2];
    for (UInt32 frame = 0; frame < total; frame += MX_PERIOD) {
        cycle.mInputTime.mSampleTime = cycle.mOutputTime.mSampleTime = frame;
        memset(source, 0, sizeof(source));
        for (UInt32 i = 0; i < MX_PERIOD; ++i) {
            UInt32 sample = frame + i;
            if (sample >= MX_RATE && sample <= 6 * MX_RATE && sample % MX_RATE == 0) {
                source[i * 2] = source[i * 2 + 1] = 0.25f;
            }
        }
        // Deliberately read before writing each simulated device cycle.
        assert((*driver)->DoIOOperation(driver, device, input, 1, kAudioServerPlugInIOOperationReadInput,
                                       MX_PERIOD, &cycle, returned, NULL) == 0);
        assert((*driver)->DoIOOperation(driver, device, output, 1, kAudioServerPlugInIOOperationWriteMix,
                                       MX_PERIOD, &cycle, source, NULL) == 0);
        for (UInt32 i = 0; i < MX_PERIOD; ++i) {
            little16(file, (uint16_t)(int16_t)(source[i * 2] * 32767));
            little16(file, (uint16_t)(int16_t)(returned[i * 2] * 32767));
        }
    }
    assert(fclose(file) == 0);
}
int main(int argc, char **argv) {
    assert(argc == 2 || argc == 3);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    assert(plugin);
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    assert(factories && CFArrayGetCount(factories) == 1);
    driver = CFPlugInInstanceCreate(NULL, CFArrayGetValueAtIndex(factories, 0), kAudioServerPlugInTypeUUID);
    assert(driver);
    AudioServerPlugInHostInterface host = { .CopyFromStorage = storage, .WriteToStorage = writeStorage, .PropertiesChanged = changed };
    assert((*driver)->Initialize(driver, &host) == 0);
    AudioObjectID device = 0, input = 0, output = 0;
    assert(property(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, &device, sizeof(device)) == sizeof(device));
    assert(device != 0);
    assert(property(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, &input, sizeof(input)) == sizeof(input));
    assert(property(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, &output, sizeof(output)) == sizeof(output));
    assert(input && output && input != output);
    CFStringRef string = NULL;
    property(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &string, sizeof(string));
    assert(CFEqual(string, CFSTR("Mixoto Stream Mix"))); CFRelease(string);
    // Rename: stored, announced, and returned; the UID does not change.
    AudioObjectPropertyAddress nameAddress = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    Boolean nameSettable = false;
    assert((*driver)->IsPropertySettable(driver, device, getpid(), &nameAddress, &nameSettable) == 0 && nameSettable);
    CFStringRef newName = CFSTR("My Stream");
    assert((*driver)->SetPropertyData(driver, device, getpid(), &nameAddress, 0, NULL, sizeof(newName), &newName) == 0);
    assert(nameChanges == 1 && stored && CFEqual(stored, newName));
    property(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &string, sizeof(string));
    assert(CFEqual(string, newName)); CFRelease(string);
    CFStringRef badName = CFSTR("");
    assert((*driver)->SetPropertyData(driver, device, getpid(), &nameAddress, 0, NULL, sizeof(badName), &badName) != 0);
    CFTypeRef notString = kCFBooleanTrue;
    assert((*driver)->SetPropertyData(driver, device, getpid(), &nameAddress, 0, NULL, sizeof(notString), &notString) != 0);
    property(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &string, sizeof(string));
    assert(CFEqual(string, CFSTR("local.mixoto.stream-mix")));
    AudioObjectPropertyAddress prop = address(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID translated = 0; UInt32 size = 0;
    assert((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, getpid(), &prop, sizeof(string), &string,
                                    sizeof(translated), &size, &translated) == 0);
    assert(translated == device); CFRelease(string);
    AudioObjectID owned[16] = {0};
    assert(property(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, owned, sizeof(owned)) == 2 * sizeof(AudioObjectID));
    assert(owned[0] == input && owned[1] == output);
    assert(property(device, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, owned, 0) == 0);
    Float64 rate = 0;
    property(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate));
    assert(rate == MX_RATE);
    AudioValueRange rates;
    assert(property(device, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, &rates, sizeof(rates)) == sizeof(rates));
    assert(rates.mMinimum == MX_RATE && rates.mMaximum == MX_RATE);
    for (size_t i = 0; i < 2; ++i) {
        AudioStreamBasicDescription format;
        property(i == 0 ? input : output, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format));
        assert(format.mSampleRate == MX_RATE && format.mChannelsPerFrame == 2 && format.mBytesPerFrame == 8);
        assert(format.mFormatFlags == kAudioFormatFlagsNativeFloatPacked);
    }
    prop = address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    rate = 44100;
    assert((*driver)->SetPropertyData(driver, device, getpid(), &prop, 0, NULL, sizeof(rate), &rate) == kAudioDeviceUnsupportedFormatError);
    rate = MX_RATE;
    assert((*driver)->SetPropertyData(driver, device, getpid(), &prop, 0, NULL, sizeof(rate), &rate) == 0);
    prop = address(kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal);
    Boolean settable = true;
    assert((*driver)->IsPropertySettable(driver, input, getpid(), &prop, &settable) == 0 && !settable);
    UInt32 active = 0;
    assert((*driver)->SetPropertyData(driver, input, getpid(), &prop, 0, NULL, sizeof(active), &active) == kAudioHardwareUnsupportedOperationError);
    assert(scalar(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput) == MX_DELAY_FRAMES);
    assert(scalar(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) == 0);
    assert(scalar(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0);
    assert(scalar(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1);
    // Reject short buffers and bad objects.
    prop = address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal);
    assert((*driver)->GetPropertyData(driver, device, getpid(), &prop, 0, NULL, 1, &size, &string) == kAudioHardwareBadPropertySizeError);
    assert(!(*driver)->HasProperty(driver, 9999, getpid(), &prop));
    // Start a writer and two independent readers. All readers get the same mix.
    assert((*driver)->StartIO(driver, device, 1) == 0);
    assert((*driver)->StartIO(driver, device, 2) == 0);
    assert((*driver)->StartIO(driver, device, 3) == 0);
    Boolean will = false, inPlace = false;
    assert((*driver)->WillDoIOOperation(driver, device, 1, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace) == 0);
    assert(will && inPlace);
    float source[MX_PERIOD * 2], returned[MX_PERIOD * 2];
    for (size_t i = 0; i < MX_PERIOD; ++i) { source[2*i] = (float)i / 1024; source[2*i+1] = -(float)i / 1024; }
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
    cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
    assert((*driver)->DoIOOperation(driver, device, input, 2, kAudioServerPlugInIOOperationReadInput, MX_PERIOD, &cycle, returned, NULL) == 0);
    silence(returned, MX_PERIOD * 2);
    assert((*driver)->DoIOOperation(driver, device, output, 1, kAudioServerPlugInIOOperationWriteMix, MX_PERIOD, &cycle, source, NULL) == 0);
    cycle.mInputTime.mSampleTime = MX_DELAY_FRAMES;
    for (UInt32 client = 2; client <= 3; ++client) {
        assert((*driver)->DoIOOperation(driver, device, input, client, kAudioServerPlugInIOOperationReadInput, MX_PERIOD, &cycle, returned, NULL) == 0);
        assert(memcmp(source, returned, sizeof(source)) == 0);
    }
    // A wrap replaces the exact frame tag. Old audio is never replayed.
    cycle.mOutputTime.mSampleTime = MX_RING_FRAMES;
    assert((*driver)->DoIOOperation(driver, device, output, 1, kAudioServerPlugInIOOperationWriteMix, MX_PERIOD, &cycle, source, NULL) == 0);
    assert((*driver)->DoIOOperation(driver, device, input, 2, kAudioServerPlugInIOOperationReadInput, MX_PERIOD, &cycle, returned, NULL) == 0);
    silence(returned, MX_PERIOD * 2);
    cycle.mInputTime.mSampleTime = MX_RING_FRAMES + MX_DELAY_FRAMES;
    assert((*driver)->DoIOOperation(driver, device, input, 2, kAudioServerPlugInIOOperationReadInput, MX_PERIOD, &cycle, returned, NULL) == 0);
    assert(memcmp(source, returned, sizeof(source)) == 0);
    cycle.mInputTime.mSampleTime = NAN;
    assert((*driver)->DoIOOperation(driver, device, input, 2, kAudioServerPlugInIOOperationReadInput, MX_PERIOD, &cycle, returned, NULL) != 0);
    silence(returned, MX_PERIOD * 2);
    Float64 sample; UInt64 time, seed, nextSeed;
    assert((*driver)->GetZeroTimeStamp(driver, device, 2, &sample, &time, &seed) == 0);
    assert(isfinite(sample) && time <= mach_absolute_time() && seed != 0);
    assert((*driver)->StopIO(driver, device, 1) == 0);
    assert(scalar(device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1);
    assert((*driver)->StopIO(driver, device, 2) == 0);
    assert((*driver)->StopIO(driver, device, 3) == 0);
    assert(scalar(device, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0);
    assert((*driver)->StopIO(driver, device, 3) != 0);
    assert((*driver)->StartIO(driver, device, 1) == 0);
    assert((*driver)->GetZeroTimeStamp(driver, device, 1, &sample, &time, &nextSeed) == 0);
    assert(nextSeed != seed);
    cycle.mInputTime.mSampleTime = MX_DELAY_FRAMES;
    assert((*driver)->DoIOOperation(driver, device, input, 1, kAudioServerPlugInIOOperationReadInput, MX_PERIOD, &cycle, returned, NULL) == 0);
    silence(returned, MX_PERIOD * 2);
    if (argc == 3) { recordOfflineProbe(argv[2], device, input, output); }
    assert((*driver)->StopIO(driver, device, 1) == 0);
    printf("Driver bundle contract and PCM loopback tests passed.\n");
    printf("Configured transport delay: %d frames / %d Hz = %.6f ms (offline, not end-to-end).\n",
           MX_DELAY_FRAMES, MX_RATE, 1000.0 * MX_DELAY_FRAMES / MX_RATE);
    CFRelease(factories); CFRelease(plugin); CFRelease(url);
    return 0;
}
