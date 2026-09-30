import CoreAudio
import AudioToolbox
import AVFoundation

struct Device: Identifiable, Hashable {
    static let streamMixUID = "local.mixoto.stream-mix"
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
    var isStreamMix: Bool { uid == Self.streamMixUID }
    var isLoopback: Bool { isStreamMix || uid == "local.openmixer.stream-mix" || name.lowercased().contains("blackhole") }
}

enum Devices {
    static func list() throws -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try ids.withUnsafeMutableBytes { try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)) }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name, inputs: channels(id, kAudioDevicePropertyScopeInput), outputs: channels(id, kAudioDevicePropertyScopeOutput))
        }.sorted { $0.name < $1.name }
    }
    // Default playback output, not the separate system-alert sound output.
    static func defaultOutputID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id))
        return id == kAudioObjectUnknown ? nil : id
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func select(_ device: Device, node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { throw MixerError.message("The audio unit is not available.") }
        var id = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id))))
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: actual))
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size))
        guard actual == id else { throw MixerError.message("The selected audio device was not applied.") }
    }
    // Core Audio process objects: every process that has an audio client.
    static func processes() -> [(id: AudioObjectID, pid: pid_t, bundle: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var pid: pid_t = -1
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pidSize = UInt32(MemoryLayout.size(ofValue: pid))
            AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid)
            return (id, pid, string(id, kAudioProcessPropertyBundleID) ?? "")
        }
    }
    // True for an app's own process and for helpers whose bundle ID starts
    // with the app's, such as net.imput.helium.helper for net.imput.helium.
    static func belongs(_ processBundle: String, to bundle: String) -> Bool {
        processBundle == bundle || processBundle.hasPrefix(bundle + ".")
    }
    // Calls handler on the main queue when a system property changes. The
    // listener stays for the app lifetime, like the single MixerStore.
    static func observe(_ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }
    // Sets a device name. Only the Mixoto driver accepts this; other
    // devices report the property as not settable.
    static func rename(_ device: Device, to name: String) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device.id, &address, &settable) == noErr, settable.boolValue else {
            throw MixerError.message("Update the virtual device first: Mixoto > Reinstall Virtual Device…")
        }
        var value = name as CFString
        try check(AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), &value))
    }
    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ empty: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var result = empty, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : empty
    }
    // Duration of one I/O buffer in seconds; 0 when the device does not report it.
    static func bufferDuration(_ id: AudioDeviceID) -> Double {
        let rate = value(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
        return rate > 0 ? Double(value(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(0))) / rate : 0
    }
    // Hardware delay of one direction in seconds: device and stream latency,
    // safety offset, and one I/O buffer. 0 when the device does not report it.
    static func latency(_ id: AudioDeviceID, input: Bool) -> Double {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var frames = value(id, kAudioDevicePropertyLatency, scope, UInt32(0)) + value(id, kAudioDevicePropertySafetyOffset, scope, UInt32(0))
            + value(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(0))
        let stream = value(id, kAudioDevicePropertyStreams, scope, AudioStreamID(0))
        if stream != 0 { frames += value(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0)) }
        let rate = value(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
        return rate > 0 ? Double(frames) / rate : 0
    }
    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MixerError.message("Core Audio error: \(status).") }
    }
}
