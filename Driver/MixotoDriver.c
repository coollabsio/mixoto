/*
Mixoto adaptation of Apple's current NullAudio sample.
The unmodified sample and its license are in AppleSample/.
Source: https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in

Keep the tested Apple COM/HAL object boilerplate. Override only device identity,
fixed formats, exposed controls, clock, and PCM transport. The sample's example
volume/data-source controls are not exposed: all mixing controls live in the app.
*/
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include "Loopback.h"
#include "AppleSample/NullAudio.c"

#define MX_DEVICE_UID "local.mixoto.stream-mix"
#define MX_BOX_UID "local.mixoto.audio-box"
#define MX_DEFAULT_NAME "Mixoto Stream Mix"
#define MX_NAME_KEY CFSTR("device name")
static MXLoopback gLoopback;
static UInt64 gClockSeed = 0;
// User-chosen device name. Clients find the device by its fixed UID, so a
// rename changes only what they display. Persisted with the host's storage.
static pthread_mutex_t gNameMutex = PTHREAD_MUTEX_INITIALIZER;
static CFStringRef gDeviceName = NULL;

static bool MXValidName(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) { return false; }
    CFIndex length = CFStringGetLength((CFStringRef)value);
    return length >= 1 && length <= 64;
}
// Returns a retained name; the HAL releases strings it receives.
static CFStringRef MXCopyName(void) {
    pthread_mutex_lock(&gNameMutex);
    CFStringRef name = gDeviceName ? (CFStringRef)CFRetain(gDeviceName) : CFSTR(MX_DEFAULT_NAME);
    pthread_mutex_unlock(&gNameMutex);
    return name;
}
static void MXSetName(CFStringRef name) {
    CFStringRef copy = CFStringCreateCopy(NULL, name);
    pthread_mutex_lock(&gNameMutex);
    CFStringRef old = gDeviceName;
    gDeviceName = copy;
    pthread_mutex_unlock(&gNameMutex);
    if (old) { CFRelease(old); }
}

static bool MXObject(AudioObjectID object) {
    return object == kObjectID_PlugIn || object == kObjectID_Box ||
           object == kObjectID_Device || object == kObjectID_Stream_Input || object == kObjectID_Stream_Output;
}
static bool MXStream(AudioObjectID object) {
    return object == kObjectID_Stream_Input || object == kObjectID_Stream_Output;
}
static bool MXLocal(AudioObjectID object, AudioObjectPropertySelector selector) {
    if (selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyModelName || selector == kAudioObjectPropertyManufacturer ||
        selector == kAudioObjectPropertyCustomPropertyInfoList) { return true; }
    if (object == kObjectID_PlugIn) {
        return selector == kAudioPlugInPropertyTranslateUIDToDevice || selector == kAudioPlugInPropertyTranslateUIDToBox;
    }
    if (object == kObjectID_Box) { return selector == kAudioBoxPropertyBoxUID; }
    if (object == kObjectID_Device) {
        switch (selector) {
            case kAudioObjectPropertyOwnedObjects:
            case kAudioObjectPropertyElementName:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return true;
        }
    }
    return MXStream(object) && (selector == kAudioStreamPropertyVirtualFormat ||
        selector == kAudioStreamPropertyPhysicalFormat || selector == kAudioStreamPropertyAvailableVirtualFormats ||
        selector == kAudioStreamPropertyAvailablePhysicalFormats);
}
static UInt32 MXSize(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    switch (address->mSelector) {
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioObjectPropertyControlList: return 0;
        case kAudioObjectPropertyOwnedObjects:
            return (address->mScope == kAudioObjectPropertyScopeGlobal ? 2 : 1) * sizeof(AudioObjectID);
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyElementName:
        case kAudioObjectPropertyManufacturer:
        case kAudioBoxPropertyBoxUID:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: return sizeof(CFStringRef);
        case kAudioDevicePropertyNominalSampleRate: return sizeof(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates: return sizeof(AudioValueRange);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: return sizeof(AudioStreamBasicDescription);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: return sizeof(AudioStreamRangedDescription);
        default: (void)object; return sizeof(UInt32);
    }
}
static AudioStreamBasicDescription MXFormat(void) {
    return (AudioStreamBasicDescription){ .mSampleRate = MX_RATE, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = 8, .mFramesPerPacket = 1,
        .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32 };
}
static Boolean MXHasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                             const AudioObjectPropertyAddress *address) {
    if (driver != gAudioServerPlugInDriverRef || !MXObject(object) || !address) { return false; }
    if (address->mSelector == kPlugIn_CustomPropertyID || address->mSelector == kAudioDevicePropertyIcon) { return false; }
    return MXLocal(object, address->mSelector) || NullAudio_HasProperty(driver, object, pid, address);
}
static OSStatus MXIsSettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                             const AudioObjectPropertyAddress *address, Boolean *settable) {
    if (!settable || !address) { return kAudioHardwareIllegalOperationError; }
    if (!MXHasProperty(driver, object, pid, address)) { return kAudioHardwareUnknownPropertyError; }
    if (MXLocal(object, address->mSelector) || object == kObjectID_Box) {
        // HAL can set the same fixed format/rate during client setup.
        *settable = (object == kObjectID_Device && address->mSelector == kAudioDevicePropertyNominalSampleRate) ||
                    (object == kObjectID_Device && address->mSelector == kAudioObjectPropertyName) ||
                    (MXStream(object) && (address->mSelector == kAudioStreamPropertyPhysicalFormat ||
                    address->mSelector == kAudioStreamPropertyVirtualFormat));
        return 0;
    }
    // All other sample properties are read-only. In particular, do not expose
    // its example stream-activity and box controls as writable app controls.
    *settable = false;
    return 0;
}
static OSStatus MXGetSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                          const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                          const void *qualifier, UInt32 *size) {
    if (!size || !address) { return kAudioHardwareIllegalOperationError; }
    if (!MXHasProperty(driver, object, pid, address)) { return kAudioHardwareUnknownPropertyError; }
    if (MXLocal(object, address->mSelector)) { *size = MXSize(object, address); return 0; }
    return NullAudio_GetPropertyDataSize(driver, object, pid, address, qualifierSize, qualifier, size);
}
static OSStatus MXGetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                          const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                          const void *qualifier, UInt32 capacity, UInt32 *size, void *data) {
    if (!size || !address) { return kAudioHardwareIllegalOperationError; }
    *size = 0;
    if (!MXHasProperty(driver, object, pid, address)) { return kAudioHardwareUnknownPropertyError; }
    if (!MXLocal(object, address->mSelector)) {
        return NullAudio_GetPropertyData(driver, object, pid, address, qualifierSize, qualifier, capacity, size, data);
    }
    UInt32 needed = MXSize(object, address);
    bool array = address->mSelector == kAudioObjectPropertyOwnedObjects;
    if (!array && capacity < needed) { return kAudioHardwareBadPropertySizeError; }
    if (needed && !data && capacity) { return kAudioHardwareIllegalOperationError; }
    *size = needed;
    switch (address->mSelector) {
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioObjectPropertyControlList: return 0;
        case kAudioObjectPropertyName:
            *(CFStringRef *)data = MXStream(object) ?
                (object == kObjectID_Stream_Input ? CFSTR("Stream Mix input") : CFSTR("Stream Mix output")) :
                (object == kObjectID_Device ? MXCopyName() : CFSTR(MX_DEFAULT_NAME)); break;
        case kAudioObjectPropertyManufacturer: *(CFStringRef *)data = CFSTR("Mixoto"); break;
        case kAudioObjectPropertyModelName: *(CFStringRef *)data = CFSTR("Mixoto Stream Mix"); break;
        case kAudioObjectPropertyElementName:
            *(CFStringRef *)data = address->mElement == 0 ? CFSTR("Main") :
                (address->mElement == 1 ? CFSTR("Left") : (address->mElement == 2 ? CFSTR("Right") : CFSTR("Unknown"))); break;
        case kAudioBoxPropertyBoxUID: *(CFStringRef *)data = CFSTR(MX_BOX_UID); break;
        case kAudioDevicePropertyDeviceUID: *(CFStringRef *)data = CFSTR(MX_DEVICE_UID); break;
        case kAudioDevicePropertyModelUID: *(CFStringRef *)data = CFSTR("local.mixoto.stream-mix.model"); break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox: {
            if (qualifierSize != sizeof(CFStringRef) || !qualifier || !*(CFStringRef const *)qualifier) {
                return kAudioHardwareBadPropertySizeError;
            }
            bool device = address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice;
            *(AudioObjectID *)data = CFEqual(*(CFStringRef const *)qualifier, device ? CFSTR(MX_DEVICE_UID) : CFSTR(MX_BOX_UID)) ?
                (device ? kObjectID_Device : kObjectID_Box) : kAudioObjectUnknown;
            break;
        }
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID objects[2] = { kObjectID_Stream_Input, kObjectID_Stream_Output };
            if (address->mScope == kAudioObjectPropertyScopeOutput) { objects[0] = kObjectID_Stream_Output; }
            *size = (capacity / sizeof(AudioObjectID) < needed / sizeof(AudioObjectID) ?
                     capacity / sizeof(AudioObjectID) : needed / sizeof(AudioObjectID)) * sizeof(AudioObjectID);
            if (*size) { memcpy(data, objects, *size); }
            break;
        }
        case kAudioDevicePropertyNominalSampleRate: *(Float64 *)data = MX_RATE; break;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *(AudioValueRange *)data = (AudioValueRange){ MX_RATE, MX_RATE }; break;
        case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32 *)data = MX_PERIOD; break;
        case kAudioDevicePropertyLatency:
            *(UInt32 *)data = address->mScope == kAudioObjectPropertyScopeInput ? MX_DELAY_FRAMES : 0; break;
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *(UInt32 *)data = 0; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // It can be chosen as a microphone, but not as the system sound output.
            *(UInt32 *)data = address->mScope == kAudioObjectPropertyScopeInput ? 1 : 0; break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *(AudioStreamBasicDescription *)data = MXFormat(); break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *(AudioStreamRangedDescription *)data = (AudioStreamRangedDescription){ MXFormat(), { MX_RATE, MX_RATE } }; break;
        default: return kAudioHardwareUnknownPropertyError;
    }
    return 0;
}
static OSStatus MXSetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                          const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                          const void *qualifier, UInt32 size, const void *data) {
    (void)qualifierSize; (void)qualifier;
    Boolean settable = false;
    OSStatus result = MXIsSettable(driver, object, pid, address, &settable);
    if (result) { return result; }
    if (!settable) { return kAudioHardwareUnsupportedOperationError; }
    if (!data || size != MXSize(object, address)) { return kAudioHardwareBadPropertySizeError; }
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        return *(const Float64 *)data == MX_RATE ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    if (object == kObjectID_Device && address->mSelector == kAudioObjectPropertyName) {
        CFStringRef name = *(const CFStringRef *)data;
        if (!MXValidName(name)) { return kAudioHardwareIllegalOperationError; }
        MXSetName(name);
        if (gPlugIn_Host->WriteToStorage) { gPlugIn_Host->WriteToStorage(gPlugIn_Host, MX_NAME_KEY, name); }
        if (gPlugIn_Host->PropertiesChanged) {
            AudioObjectPropertyAddress changed = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &changed);
        }
        return 0;
    }
    if (MXStream(object) && (address->mSelector == kAudioStreamPropertyVirtualFormat ||
                             address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        const AudioStreamBasicDescription *format = data;
        AudioStreamBasicDescription expected = MXFormat();
        return format->mSampleRate == expected.mSampleRate && format->mFormatID == expected.mFormatID &&
            format->mFormatFlags == expected.mFormatFlags && format->mBytesPerFrame == expected.mBytesPerFrame &&
            format->mBytesPerPacket == expected.mBytesPerPacket && format->mFramesPerPacket == 1 &&
            format->mChannelsPerFrame == 2 && format->mBitsPerChannel == 32 ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus MXInitialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if (!host) { return kAudioHardwareIllegalOperationError; }
    struct mach_timebase_info timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) { return kAudioHardwareUnspecifiedError; }
    gPlugIn_Host = host;
    gBox_Acquired = true;
    gBox_Name = CFSTR(MX_DEFAULT_NAME);
    CFPropertyListRef stored = NULL;
    if (host->CopyFromStorage && host->CopyFromStorage(host, MX_NAME_KEY, &stored) == 0 && stored) {
        if (MXValidName(stored)) { MXSetName((CFStringRef)stored); }
        CFRelease(stored);
    }
    gDevice_SampleRate = MX_RATE;
    gDevice_HostTicksPerFrame = (Float64)timebase.denom / timebase.numer * 1000000000.0 / MX_RATE;
    MXLoopbackReset(&gLoopback);
    return 0;
}
static OSStatus MXConfiguration(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void *info) {
    (void)info;
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return action == MX_RATE ? 0 : kAudioDeviceUnsupportedFormatError;
}
static OSStatus MXStartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)client;
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    pthread_mutex_lock(&gDevice_IOMutex);
    OSStatus result = 0;
    if (gDevice_IOIsRunning == UINT64_MAX) { result = kAudioHardwareIllegalOperationError; }
    else if (gDevice_IOIsRunning++ == 0) {
        MXLoopbackReset(&gLoopback);
        gDevice_AnchorHostTime = mach_absolute_time();
        gDevice_NumberTimeStamps = 0;
        ++gClockSeed;
    }
    pthread_mutex_unlock(&gDevice_IOMutex);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return result;
}
static OSStatus MXStopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)client;
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    pthread_mutex_lock(&gDevice_IOMutex);
    OSStatus result = 0;
    if (gDevice_IOIsRunning == 0) { result = kAudioHardwareIllegalOperationError; }
    else if (--gDevice_IOIsRunning == 0) { MXLoopbackReset(&gLoopback); }
    pthread_mutex_unlock(&gDevice_IOMutex);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return result;
}
static OSStatus MXZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                               Float64 *sample, UInt64 *host, UInt64 *seed) {
    (void)client;
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    if (!sample || !host || !seed) { return kAudioHardwareIllegalOperationError; }
    pthread_mutex_lock(&gDevice_IOMutex);
    Float64 ticks = gDevice_HostTicksPerFrame * MX_PERIOD;
    UInt64 now = mach_absolute_time();
    UInt64 elapsed = now >= gDevice_AnchorHostTime ? now - gDevice_AnchorHostTime : 0;
    gDevice_NumberTimeStamps = ticks > 0 ? (UInt64)((Float64)elapsed / ticks) : 0;
    *sample = (Float64)(gDevice_NumberTimeStamps * MX_PERIOD);
    *host = gDevice_AnchorHostTime + (UInt64)((Float64)gDevice_NumberTimeStamps * ticks);
    *seed = gClockSeed;
    pthread_mutex_unlock(&gDevice_IOMutex);
    return 0;
}
static OSStatus MXDoIO(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                       UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                       void *buffer, void *secondary) {
    (void)client; (void)secondary;
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    if (!cycle || !buffer || frames > MX_MAX_IO_FRAMES) { return kAudioHardwareIllegalOperationError; }
    bool read = operation == kAudioServerPlugInIOOperationReadInput;
    if ((!read && operation != kAudioServerPlugInIOOperationWriteMix) ||
        stream != (read ? kObjectID_Stream_Input : kObjectID_Stream_Output)) { return kAudioHardwareIllegalOperationError; }
    const AudioTimeStamp *time = read ? &cycle->mInputTime : &cycle->mOutputTime;
    if (!(time->mFlags & kAudioTimeStampSampleTimeValid) || !isfinite(time->mSampleTime) ||
        time->mSampleTime < 0 || time->mSampleTime > 9007199254740992.0 - frames) {
        if (read) { memset(buffer, 0, (size_t)frames * MX_CHANNELS * sizeof(float)); }
        return kAudioHardwareIllegalOperationError;
    }
    int64_t start = (int64_t)floor(time->mSampleTime);
    if (read) { MXLoopbackRead(&gLoopback, start - MX_DELAY_FRAMES, frames, buffer); }
    else { MXLoopbackWrite(&gLoopback, (uint64_t)start, frames, buffer); }
    return 0;
}

__attribute__((visibility("default")))
void *Mixoto_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    // Install immutable interface overrides once before the host discovers it.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAudioServerPlugInDriverInterface.Initialize = MXInitialize;
        gAudioServerPlugInDriverInterface.HasProperty = MXHasProperty;
        gAudioServerPlugInDriverInterface.IsPropertySettable = MXIsSettable;
        gAudioServerPlugInDriverInterface.GetPropertyDataSize = MXGetSize;
        gAudioServerPlugInDriverInterface.GetPropertyData = MXGetData;
        gAudioServerPlugInDriverInterface.SetPropertyData = MXSetData;
        gAudioServerPlugInDriverInterface.PerformDeviceConfigurationChange = MXConfiguration;
        gAudioServerPlugInDriverInterface.StartIO = MXStartIO;
        gAudioServerPlugInDriverInterface.StopIO = MXStopIO;
        gAudioServerPlugInDriverInterface.GetZeroTimeStamp = MXZeroTimeStamp;
        gAudioServerPlugInDriverInterface.DoIOOperation = MXDoIO;
    });
    return NullAudio_Create(allocator, type);
}
