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
    private var selectedFormat: AudioStreamBasicDescription?
    private var reportedFailure = false
    private let receive: (AVAudioPCMBuffer) -> Void
    private let failure: (String) -> Void
    init(receive: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (String) -> Void) {
        self.receive = receive; self.failure = failure
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
    // Captures a mixdown of the given process objects (an app and its helpers).
    func start(processes: [AudioObjectID], pids: [pid_t]) async throws {
        try await onSetupQueue {
            self.lifecycleLock.lock(); defer { self.lifecycleLock.unlock() }
            self.pids = pids
            try self.startTap(CATapDescription(stereoMixdownOfProcesses: processes))
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
        pids.removeAll()
        selectedFormat = nil
        queue.sync {}
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
    deinit { stop() }
}
