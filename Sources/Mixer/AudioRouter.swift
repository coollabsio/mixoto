import AVFoundation
import AudioToolbox
import CoreAudio

final class OutputBus {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var budgets: [UUID: QueueBudget] = [:]
    private var active = false
    private var dropped = 0
    private var received = 0
    let device: Device?
    private let monitor: Bool
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    var droppedBlocks: Int { lock.lock(); defer { lock.unlock() }; return dropped }
    var receivedBlocks: Int { lock.lock(); defer { lock.unlock() }; return received }
    var isHealthy: Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, engine.isRunning else { return false }
        guard let device else { return true }
        guard let unit = engine.outputNode.audioUnit else { return false }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: actual))
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr && actual == device.id
    }

    init(device: Device?, channels: [Channel], monitor: Bool) throws {
        self.device = device; self.monitor = monitor
        if let device {
            try Devices.select(device, node: engine.outputNode)
        } else {
            // Offline mode proves the actual graph without opening hardware.
            try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        }
        // AVAudioEngine sums sources. No limiter: keep gains low to avoid clipping.
        // Keep the main mixer connected before start, even with no channels.
        _ = engine.mainMixerNode
        sync(channels)
        engine.prepare()
        try engine.start()
        active = true
        if !engine.isInManualRenderingMode { players.values.forEach { $0.play() } }
    }
    // Adds, removes, and updates channel players while the engine runs.
    func sync(_ channels: [Channel]) {
        lock.lock(); defer { lock.unlock() }
        let wanted = Dictionary(channels.filter { !$0.source.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, player) in players where wanted[id] == nil {
            player.stop(); engine.detach(player)
            players[id] = nil; budgets[id] = nil
        }
        for (id, channel) in wanted {
            if players[id] == nil {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: Self.format)
                players[id] = player
                budgets[id] = QueueBudget()
                if engine.isRunning, !engine.isInManualRenderingMode { player.play() }
            }
            players[id]?.volume = monitor ? channel.monitorGain : channel.streamGain
        }
    }
    func update(_ channel: Channel, monitor: Bool) {
        lock.lock(); defer { lock.unlock() }
        players[channel.id]?.volume = monitor ? channel.monitorGain : channel.streamGain
    }
    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard engine.isInManualRenderingMode,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames) else {
            throw MixerError.message("Offline rendering is not available.")
        }
        let time = AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: Self.format.sampleRate)
        players.values.filter { !$0.isPlaying }.forEach { $0.play(at: time) }
        guard try engine.renderOffline(frames, to: buffer) == .success else {
            throw MixerError.message("Offline rendering did not succeed.")
        }
        return buffer
    }
    func feed(_ buffer: AVAudioPCMBuffer, channel: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard active, let player = players[channel], let budget = budgets[channel] else { return }
        received += 1
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard budget.reserve(duration) else { dropped += 1; return }
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in budget.release(duration) }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        players.values.forEach { $0.stop() }
        engine.stop()
    }
    deinit { stop() }
}

// Converter is used only by one microphone sink. AVAudioEngine supplies hardware format.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var selectedDevice: Device?
    private var selectedFormat: AVAudioFormat?
    var isHealthy: Bool {
        guard engine.isRunning, let selectedDevice, let selectedFormat,
              let unit = engine.inputNode.audioUnit else { return false }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: actual))
        let currentFormat = engine.inputNode.outputFormat(forBus: 0)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr && actual == selectedDevice.id && currentFormat.sampleRate == selectedFormat.sampleRate && currentFormat.channelCount == selectedFormat.channelCount
    }
    func start(device: Device, receive: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (String) -> Void) throws {
        let input = engine.inputNode
        try Devices.select(device, node: input)
        let format = input.outputFormat(forBus: 0)
        selectedDevice = device; selectedFormat = format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MixerError.message("The microphone format is not supported.")
        }
        let normalizer = try PCMNormalizer(format: format)
        var reportedFailure = false
        // A sink node receives each hardware I/O cycle (~10 ms). An input tap
        // delivers ~100 ms blocks, which added delay and overran the queue budget.
        let sink = AVAudioSinkNode { _, _, list in
            guard !reportedFailure else { return noErr }
            do { if let converted = try normalizer.copy(list) { receive(converted) } }
            catch { reportedFailure = true; failure(error.localizedDescription) }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        try engine.start()
    }
    func stop() { engine.stop() }
    deinit { stop() }
}

// Audio callbacks read the current buses; the router replaces them on the main actor.
final class BusSet: @unchecked Sendable {
    private let lock = NSLock()
    private var buses: [OutputBus] = []
    private var meters: [UUID: (peak: Float, time: TimeInterval)] = [:]
    // Meter ballistics: instant rise, then a fall of this many dB per second.
    static let releaseDBPerSecond: Float = 30
    func set(_ value: [OutputBus]) { lock.lock(); buses = value; lock.unlock() }
    func feed(_ buffer: AVAudioPCMBuffer, channel: UUID) {
        let peak = Self.peak(buffer), now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let current = buses
        let held = meters[channel].map { Self.decay($0.peak, over: now - $0.time) } ?? 0
        meters[channel] = (max(held, peak), now)
        lock.unlock()
        current.forEach { $0.feed(buffer, channel: channel) }
    }
    // Current meter level of a channel's input, before gain. Safe from any thread.
    func level(_ channel: UUID, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Float {
        lock.lock(); defer { lock.unlock() }
        return meters[channel].map { Self.decay($0.peak, over: now - $0.time) } ?? 0
    }
    static func decay(_ peak: Float, over seconds: TimeInterval) -> Float {
        peak * pow(10, -releaseDBPerSecond * Float(max(0, seconds)) / 20)
    }
    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[channel][frame])) }
        }
        return peak.isFinite ? peak : 0
    }
}

@MainActor
final class AudioRouter {
    private enum Capture {
        case app(ProcessCapture), mic(MicrophoneCapture)
        var isHealthy: Bool { switch self { case .app(let c): c.isHealthy; case .mic(let c): c.isHealthy } }
        func stop() { switch self { case .app(let c): c.stop(); case .mic(let c): c.stop() } }
    }
    private var monitor: OutputBus?
    private var stream: OutputBus?
    private let buses = BusSet()
    private var captures: [UUID: (source: String, capture: Capture)] = [:]
    var droppedBlocks: Int { max(monitor?.droppedBlocks ?? 0, stream?.droppedBlocks ?? 0) }
    var receivedBlocks: Int { monitor?.receivedBlocks ?? stream?.receivedBlocks ?? 0 }
    func level(_ channel: UUID) -> Float { buses.level(channel) }
    var isHealthy: Bool { (monitor?.isHealthy ?? true) && (stream?.isHealthy ?? true) && captures.values.allSatisfy(\.capture.isHealthy) }

    // Brings the running graph to the settings without a full stop. Unchanged
    // channels keep capturing. Returns problems to show; never throws.
    func apply(settings: Settings, devices: [Device], defaultOutputID: AudioDeviceID? = nil, failure: @escaping (String) -> Void) async -> [String] {
        var problems: [String] = []
        let monitorDevice = settings.monitorDevice(in: devices, defaultOutputID: defaultOutputID)
        if monitor.map({ !$0.isHealthy || $0.device?.uid != monitorDevice?.uid || $0.device?.id != monitorDevice?.id }) == true { monitor?.stop(); monitor = nil }
        if stream.map({ !$0.isHealthy }) == true { stream?.stop(); stream = nil }
        if monitor == nil, !settings.monitorUID.isEmpty {
            if let device = monitorDevice {
                do { monitor = try OutputBus(device: device, channels: [], monitor: true) } catch { problems.append("Monitor: \(error.localizedDescription)") }
            } else {
                problems.append(settings.monitorUID == Settings.defaultMonitorUID
                    ? "The default system output is unavailable or is a loopback device. Choose another Monitor output."
                    : "The Monitor device is not available.")
            }
        }
        if stream == nil {
            if let device = devices.first(where: { $0.isStreamMix && $0.inputs == 2 && $0.outputs == 2 }) {
                do { stream = try OutputBus(device: device, channels: [], monitor: false) } catch { problems.append("Stream Mix: \(error.localizedDescription)") }
            } else { problems.append("Mixoto Stream Mix is not available. Install the virtual device.") }
        }
        buses.set([monitor, stream].compactMap { $0 })

        var (wanted, skipped) = settings.activeSources()
        problems += skipped
        // The System key lists excluded process objects, so the tap is rebuilt
        // when assigned apps (or their helper processes) change.
        let processes = Devices.processes()
        let owned = Set(wanted.values.filter { $0.hasPrefix("app:") }.map { String($0.dropFirst(4)) })
        // App keys list the app's current process objects, so a new or ended
        // helper process (for example a browser's audio helper) rebuilds the tap.
        for (id, source) in wanted where source.hasPrefix("app:") {
            let objects = processes.filter { Devices.belongs($0.bundle, to: String(source.dropFirst(4))) }.map(\.id).sorted()
            if objects.isEmpty {
                wanted[id] = nil
                problems.append("\(settings.channels.first(where: { $0.id == id })?.name ?? "Channel"): waiting for the app to play audio.")
            } else { wanted[id] = source + "|" + objects.map(String.init).joined(separator: ",") }
        }
        if let id = wanted.first(where: { $0.value == Channel.system })?.key {
            let excluded = processes.filter { process in
                process.pid == getpid() || owned.contains { Devices.belongs(process.bundle, to: $0) }
            }.map(\.id).sorted()
            // Never tap without excluding Mixoto: Monitor output would feed back.
            if processes.contains(where: { $0.pid == getpid() }) {
                wanted[id] = Channel.system + ":" + excluded.map(String.init).joined(separator: ",")
            } else { wanted[id] = nil; problems.append("System: waiting for Mixoto audio output.") }
        }
        let active = monitor != nil || stream != nil ? wanted : [:]
        monitor?.sync(settings.channels.filter { active[$0.id] != nil })
        stream?.sync(settings.channels.filter { active[$0.id] != nil })
        for (id, entry) in captures where active[id] != entry.source || !entry.capture.isHealthy {
            entry.capture.stop(); captures[id] = nil
        }
        for (id, source) in active where captures[id] == nil {
            let buses = buses
            let receive: (AVAudioPCMBuffer) -> Void = { buses.feed($0, channel: id) }
            do {
                if source.hasPrefix(Channel.system) {
                    let excluded = source.dropFirst(Channel.system.count + 1).split(separator: ",").compactMap { AudioObjectID($0) }
                    let capture = ProcessCapture(receive: receive, failure: failure)
                    try await capture.start(excluding: excluded)
                    captures[id] = (source, .app(capture))
                } else if source.hasPrefix("app:") {
                    let objects = Set(source.split(separator: "|").last!.split(separator: ",").compactMap { AudioObjectID($0) })
                    let members = processes.filter { objects.contains($0.id) }
                    let capture = ProcessCapture(receive: receive, failure: failure)
                    try await capture.start(processes: members.map(\.id), pids: members.map(\.pid).filter { $0 > 0 })
                    captures[id] = (source, .app(capture))
                } else {
                    guard let device = devices.first(where: { $0.uid == String(source.dropFirst(4)) && $0.inputs > 0 && !$0.isLoopback }) else {
                        throw MixerError.message("The microphone is not available.")
                    }
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MixerError.message("Microphone permission was denied. Open System Settings > Privacy & Security.") }
                    let microphone = MicrophoneCapture()
                    try microphone.start(device: device, receive: receive, failure: failure)
                    captures[id] = (source, .mic(microphone))
                }
            } catch {
                let name = settings.channels.first(where: { $0.id == id })?.name ?? "Channel"
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        return problems
    }
    func stop() {
        captures.values.forEach { $0.capture.stop() }
        captures.removeAll()
        buses.set([])
        monitor?.stop(); stream?.stop()
        monitor = nil; stream = nil
    }
}
