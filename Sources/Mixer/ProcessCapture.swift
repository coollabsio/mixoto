import AppKit
import AVFoundation
import CoreAudio

struct RunningApp: Identifiable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    static func list() -> [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, isUserApp(app),
                  seen.insert(bundle).inserted else { return nil }
            return RunningApp(bundleIdentifier: bundle, name: app.localizedName ?? bundle)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    // Dock apps, plus menu-bar apps installed as their own .app bundle. Skips
    // helpers inside another app, system agents, and updaters under Library.
    private static func isUserApp(_ app: NSRunningApplication) -> Bool {
        if app.activationPolicy == .regular { return true }
        guard app.activationPolicy == .accessory, let path = app.bundleURL?.path, path.hasSuffix(".app") else { return false }
        return !path.dropLast(4).contains(".app/") && !path.hasPrefix("/System/") && !path.contains("/Library/")
    }
}

// One instance per capture callback queue. Copies borrowed HAL data and converts
// to the graph format before the HAL returns. No borrowed buffers reach players.
final class PCMNormalizer {
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    init(format: AVAudioFormat) throws {
        guard (1...2).contains(format.channelCount), format.sampleRate > 0,
              let converter = AVAudioConverter(from: format, to: OutputBus.format) else {
            throw MixerError.message("The source audio format is not supported. Use a mono or stereo source.")
        }
        self.format = format; self.converter = converter
    }
    func copy(_ list: UnsafePointer<AudioBufferList>) throws -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count == (format.isInterleaved ? 1 : Int(format.channelCount)),
              buffers.allSatisfy({ $0.mData != nil }),
              let first = buffers.first else { return nil }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frames = first.mDataByteSize / bytesPerFrame
        guard buffers.allSatisfy({ $0.mDataByteSize == first.mDataByteSize }) else { return nil }
        guard frames > 0, frames <= 48_000,
              let owned = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        owned.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for index in buffers.indices {
            guard let target = destination[index].mData,
                  destination[index].mDataByteSize >= buffers[index].mDataByteSize else { return nil }
            memcpy(target, buffers[index].mData!, Int(buffers[index].mDataByteSize))
        }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * 48_000 / format.sampleRate)) + 64
        guard let result = AVAudioPCMBuffer(pcmFormat: OutputBus.format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return owned
        }
        if status == .error { throw error ?? MixerError.message("Cannot convert application audio.") as NSError }
        return result.frameLength > 0 ? result : nil
    }
}

// HAL lifetime state is protected by lifecycleLock. Callback-only state is
// confined to queue; stop drains that queue before destroying its resources.
final class ProcessCapture: @unchecked Sendable {
    private let lifecycleLock = NSRecursiveLock()
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Mixoto.process-tap")
    private let setupQueue = DispatchQueue(label: "Mixoto.process-tap-setup")
    private var started = false
    private var pids: [pid_t] = []
    private var processes: [AudioObjectID] = []
    // Audio changes of the tapped processes, such as a short input start. The
    // tap can stay silent after one (seen with Helium); the router checks it.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    // Own lock and queue: stop() removes listeners while it holds lifecycleLock.
    private let changeLock = NSLock()
    private let listenerQueue = DispatchQueue(label: "Mixoto.process-tap-listener")
    private var changeTime: TimeInterval = 0
    private var observedSince: TimeInterval = 0
    // Changes that Mixoto's own captures cause: device start and stop, and the
    // process mute state ('pomt') that each tap sets with mutedWhenTapped.
    static let ignoredProperties: Set<AudioObjectPropertySelector> = [kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceIsRunningSomewhere, 0x706F_6D74]
    private var selectedFormat: AudioStreamBasicDescription?
    private var reportedFailure = false
    private let receive: (AVAudioPCMBuffer) -> Void
    private let failure: (String) -> Void
    private let changed: () -> Void
    init(receive: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (String) -> Void, changed: @escaping () -> Void = {}) {
        self.receive = receive; self.failure = failure; self.changed = changed
    }
    var latency: Double {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return aggregateID == 0 ? 0 : Devices.latency(aggregateID, input: true)
    }
    var isHealthy: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard started, aggregateID != 0,
              pids.allSatisfy({ kill($0, 0) == 0 }) else { return false }
        guard let selectedFormat else { return false }
        var currentFormat = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: currentFormat))
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &currentFormat) == noErr,
              currentFormat.mSampleRate == selectedFormat.mSampleRate,
              currentFormat.mFormatID == selectedFormat.mFormatID,
              currentFormat.mFormatFlags == selectedFormat.mFormatFlags,
              currentFormat.mBytesPerFrame == selectedFormat.mBytesPerFrame,
              currentFormat.mChannelsPerFrame == selectedFormat.mChannelsPerFrame else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunning
        var value: UInt32 = 0; size = UInt32(MemoryLayout.size(ofValue: value))
        return AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &value) == noErr && value != 0
    }
    // True while a tapped process plays output. Always false for the System tap.
    var isPlaying: Bool {
        lifecycleLock.lock(); let objects = processes; lifecycleLock.unlock()
        return objects.contains(where: Devices.isRunningOutput)
    }
    // Time of the last audio change of a tapped process; 0 when none.
    var lastChange: TimeInterval { changeLock.lock(); defer { changeLock.unlock() }; return changeTime }
    // Records an app audio reconfiguration found in the coreaudiod log
    // (AudioClientLog). After one, the tap can deliver silence or garbled
    // audio, so the router rebuilds it even when it has sound.
    private(set) var reconfigured = false
    func noteReconfiguration() {
        changeLock.lock(); changeTime = ProcessInfo.processInfo.systemUptime; reconfigured = true; changeLock.unlock()
    }
    // True when the tap includes this process. nil (no process ID) matches every app tap.
    func includes(_ pid: pid_t?) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return !pids.isEmpty && (pid == nil || pids.contains(pid!))
    }
    // Listens to every property of the tapped processes, the tap, and its
    // private device. Helium opened an input for 13 ms without a change of a
    // process "running" property, so no single property is enough.
    private func observe(_ objects: [AudioObjectID]) {
        changeLock.lock(); observedSince = ProcessInfo.processInfo.systemUptime; changeLock.unlock()
        let named = objects.map { ($0, "process \($0)") } + [(tapID, "tap"), (aggregateID, "capture device")]
        for (object, name) in named where object != 0 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard, mScope: kAudioObjectPropertyScopeWildcard, mElement: kAudioObjectPropertyElementWildcard)
            let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
                guard let self else { return }
                let selectors = UnsafeBufferPointer(start: addresses, count: Int(count)).map(\.mSelector).filter { !Self.ignoredProperties.contains($0) }
                guard !selectors.isEmpty else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.changeLock.lock()
                // Properties settle while the capture starts; that is not an app change.
                let settling = now - self.observedSince < 2
                if !settling { self.changeTime = now }
                self.changeLock.unlock()
                guard !settling else { return }
                log.notice("Audio change: \(name, privacy: .public) \(selectors.map(Self.fourCC).joined(separator: ","), privacy: .public)")
                self.changed()
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr { listeners.append((object, address, block)) }
        }
    }
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(value)
    }
    // Captures a mixdown of the given process objects (an app and its helpers).
    func start(processes: [AudioObjectID], pids: [pid_t]) async throws {
        try await onSetupQueue {
            self.lifecycleLock.lock(); defer { self.lifecycleLock.unlock() }
            self.pids = pids; self.processes = processes
            try self.startTap(CATapDescription(stereoMixdownOfProcesses: processes))
            self.observe(processes)
        }
    }
    // Captures every process except the given process objects.
    func start(excluding processes: [AudioObjectID]) async throws {
        try await onSetupQueue {
            self.lifecycleLock.lock(); defer { self.lifecycleLock.unlock() }
            try self.startTap(CATapDescription(stereoGlobalTapButExcludeProcesses: processes))
        }
    }
    private func onSetupQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            setupQueue.async {
                do { try work(); completion.resume() }
                catch { completion.resume(throwing: error) }
            }
        }
    }
    private func startTap(_ description: CATapDescription) throws {
        guard tapID == 0, aggregateID == 0 else { throw MixerError.message("Application capture is already started.") }
        do {
            description.name = "Mixoto application"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try Devices.check(AudioHardwareCreateProcessTap(description, &tapID))
            var asbd = AudioStreamBasicDescription()
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout.size(ofValue: asbd))
            try Devices.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd))
            selectedFormat = asbd
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw MixerError.message("The application audio format is not available.") }
            let normalizer = try PCMNormalizer(format: format)
            log.notice("Tap format: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, interleaved=\(format.isInterleaved)")
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Mixoto private capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try Devices.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID))
            try Devices.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, input, _, _, _ in
                guard let self, !self.reportedFailure else { return }
                do { if let buffer = try normalizer.copy(input) { self.receive(buffer) } }
                catch { self.reportedFailure = true; self.failure(error.localizedDescription) }
            })
            try Devices.check(AudioDeviceStart(aggregateID, ioProc))
            started = true
        } catch { stop(); throw error }
    }
    func stop() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        if let ioProc {
            if started { AudioDeviceStop(aggregateID, ioProc) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        self.ioProc = nil; started = false
        pids.removeAll(); processes.removeAll()
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
        listeners.removeAll()
        changeLock.lock(); changeTime = 0; changeLock.unlock()
        selectedFormat = nil
        queue.sync {}
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
    deinit { stop() }
}
