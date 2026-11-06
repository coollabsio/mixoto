import AVFoundation
import AudioToolbox
import CoreAudio
import os

let log = Logger(subsystem: "io.coollabs.mixoto", category: "audio")

final class OutputBus {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var budgets: [UUID: QueueBudget] = [:]
    // Start time of each channel's current run of dropped blocks.
    private var dropStarts: [UUID: TimeInterval] = [:]
    private var channelDrops: [UUID: Int] = [:]
    // A channel that drops every block for this long has a stuck player.
    static let stuckLimit: TimeInterval = 3
    private var active = false
    private var dropped = 0
    private var received = 0
    let device: Device?
    private let monitor: Bool
    // A Monitor bus plays the Stream gains while the user previews the Stream Mix.
    private var previewStream = false
    private let outputBuffer: Double
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    var droppedBlocks: Int { lock.lock(); defer { lock.unlock() }; return dropped }
    var receivedBlocks: Int { lock.lock(); defer { lock.unlock() }; return received }
    // Audio of a channel waiting in its player, plus the output device delay.
    func latency(_ channel: UUID) -> Double? {
        lock.lock(); let budget = budgets[channel]; lock.unlock()
        guard let budget else { return nil }
        return budget.queued + (device.map { Devices.latency($0.id, input: false) } ?? 0)
    }
    private var name: String { monitor ? "Monitor" : "Stream" }
    // A channel whose player has dropped every block for stuckLimit seconds.
    func stuckChannel(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return dropStarts.first { now - $0.value > Self.stuckLimit }?.key
    }
    func drops(_ channel: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return channelDrops[channel] ?? 0 }
    // Player state of a channel, for logs.
    func state(_ channel: UUID) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let player = players[channel] else { return "\(name): no player" }
        return "\(name): queued=\(Int((budgets[channel]?.queued ?? 0) * 1000)) ms playing=\(player.isPlaying) volume=\(player.volume) engine=\(engine.isRunning) dropped=\(dropped)"
    }
    var isHealthy: Bool {
        lock.lock(); let wasActive = active; lock.unlock()
        guard wasActive, engine.isRunning, stuckChannel() == nil else { return false }
        guard let device else { return true }
        guard let unit = engine.outputNode.audioUnit else { return false }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: actual))
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr && actual == device.id
    }

    init(device: Device?, channels: [Channel], monitor: Bool) throws {
        self.device = device; self.monitor = monitor
        outputBuffer = device.map { Devices.bufferDuration($0.id) } ?? 0
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
            players[id] = nil; budgets[id] = nil; dropStarts[id] = nil; channelDrops[id] = nil
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
            players[id]?.volume = gain(channel)
        }
    }
    func setPreviewStream(_ on: Bool, channels: [Channel]) {
        lock.lock(); defer { lock.unlock() }
        previewStream = on
        for channel in channels { players[channel.id]?.volume = gain(channel) }
    }
    private func gain(_ channel: Channel) -> Float { monitor && !previewStream ? channel.monitorGain : channel.streamGain }
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
        guard budget.reserve(duration, limit: queueLimit(block: duration, outputBuffer: outputBuffer)) else {
            dropped += 1; channelDrops[channel, default: 0] += 1
            if dropStarts[channel] == nil { dropStarts[channel] = ProcessInfo.processInfo.systemUptime }
            return
        }
        if let start = dropStarts.removeValue(forKey: channel), ProcessInfo.processInfo.systemUptime - start > 0.5 {
            log.notice("\(self.name, privacy: .public) bus dropped all audio of channel \(channel.uuidString.prefix(8), privacy: .public) for \(ProcessInfo.processInfo.systemUptime - start, format: .fixed(precision: 1)) s")
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in budget.release(duration) }
    }
    // Stops the engine outside the lock: engine.stop() can wait on Core Audio,
    // and feed() takes the lock on audio threads.
    func stop() {
        lock.lock(); active = false; let players = Array(players.values); lock.unlock()
        log.notice("\(self.name, privacy: .public) bus stop: \(self.device?.name ?? "offline", privacy: .public)")
        players.forEach { $0.stop() }
        engine.stop()
    }
    deinit { stop() }
}

// Converter is used only by one microphone sink. AVAudioEngine supplies hardware format.
// Input -> Low Cut -> Voice Focus -> sink. Low Cut stays in the graph and is
// bypassed when off. Voice Focus uses about 13 MB, so it is in the graph only
// while on; turning it on or off restarts the capture.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let lowCut = AVAudioUnitEQ(numberOfBands: 2)
    private let voiceFocus: AVAudioUnitEffect?
    private var selectedDevice: Device?
    private var selectedFormat: AVAudioFormat?
    private var clipguard: Bool?
    // Apple's on-device voice isolation (macOS 13+). Adds about 56 ms delay while on.
    static let voiceFocusComponent = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                               componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    static let voiceFocusAvailable = !AVAudioUnitComponentManager.shared().components(matching: voiceFocusComponent).isEmpty
    init(voiceFocus: Bool) {
        // Two 12 dB/octave high-pass bands give a steep 24 dB/octave low cut.
        for band in lowCut.bands { band.filterType = .highPass; band.bypass = false }
        lowCut.bypass = true
        self.voiceFocus = voiceFocus && Self.voiceFocusAvailable ? AVAudioUnitEffect(audioComponentDescription: Self.voiceFocusComponent) : nil
        self.voiceFocus?.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value = AUValue(kAUSoundIsolationSoundType_Voice)
    }
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
        let chain = [input, lowCut] + [voiceFocus].compactMap { $0 } + [sink]
        chain.dropFirst().forEach(engine.attach)
        for (source, destination) in zip(chain, chain.dropFirst()) { engine.connect(source, to: destination, format: format) }
        engine.prepare()
        try engine.start()
    }
    // Applies the channel's microphone settings. Clipguard is sent to a
    // Wave:3 only when it changes or the microphone starts again.
    func update(_ channel: Channel) throws {
        for band in lowCut.bands { band.frequency = Float(max(20, channel.lowCut)) }
        lowCut.bypass = channel.lowCut <= 0 || selectedDevice?.isDigitalInput == true
        voiceFocus?.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = Channel.voiceFocusMix(channel.voiceFocusStrength)
        if let wanted = channel.clipguard, wanted != clipguard, let device = selectedDevice, Wave3.serial(device) != nil {
            try Wave3.setClipguard(wanted, device: device)
            clipguard = wanted
        }
    }
    // Input device delay plus effect delay (Voice Focus reports about 56 ms).
    var latency: Double {
        (selectedDevice.map { Devices.latency($0.id, input: true) } ?? 0) + lowCut.latency + (voiceFocus?.latency ?? 0)
    }
    func stop() { engine.stop() }
    deinit { stop() }
}

// Audio callbacks read the current buses; the router replaces them on the main actor.
// Only this set and the router own buses, and feed() holds the lock while it uses
// them, so the last release of a bus is never on an audio thread. A bus released
// there freed its AVAudioEngine, which waited on Core Audio while the thread held
// the device I/O lock: Mixoto hung when a device was added or removed.
final class BusSet: @unchecked Sendable {
    private let lock = NSLock()
    private var buses: [OutputBus] = []
    private var meters: [UUID: (peak: Float, time: TimeInterval)] = [:]
    // Last time each channel's input was not digital silence.
    private var sounds: [UUID: TimeInterval] = [:]
    // Frames received per channel, at 48 kHz after conversion.
    private var frames: [UUID: Int] = [:]
    // Meter ballistics: instant rise, then a fall of this many dB per second.
    static let releaseDBPerSecond: Float = 30
    // The old buses are released after unlock, on the caller's thread.
    func set(_ value: [OutputBus]) {
        lock.lock(); let old = buses; buses = value; lock.unlock()
        withExtendedLifetime(old) {}
    }
    func feed(_ buffer: AVAudioPCMBuffer, channel: UUID) {
        let peak = Self.peak(buffer), now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let held = meters[channel].map { Self.decay($0.peak, over: now - $0.time) } ?? 0
        meters[channel] = (max(held, peak), now)
        if peak > 0 { sounds[channel] = now }
        frames[channel, default: 0] += Int(buffer.frameLength)
        for bus in buses { bus.feed(buffer, channel: channel) }
    }
    // Current meter level of a channel's input, before gain. Safe from any thread.
    func level(_ channel: UUID, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Float {
        lock.lock(); defer { lock.unlock() }
        return meters[channel].map { Self.decay($0.peak, over: now - $0.time) } ?? 0
    }
    // Last time a channel received input, and last time that input had sound.
    func activity(_ channel: UUID) -> (input: TimeInterval, sound: TimeInterval, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (meters[channel]?.time ?? 0, sounds[channel] ?? 0, frames[channel] ?? 0)
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
        var isPlaying: Bool { if case .app(let c) = self { c.isPlaying } else { false } }
        var lastChange: TimeInterval { if case .app(let c) = self { c.lastChange } else { 0 } }
        var latency: Double { switch self { case .app(let c): c.latency; case .mic(let c): c.latency } }
        func stop() { switch self { case .app(let c): c.stop(); case .mic(let c): c.stop() } }
    }
    private var monitor: OutputBus?
    private var stream: OutputBus?
    // Monitor plays the Stream Mix while true.
    private var previewStream = false
    func previewStream(_ on: Bool, channels: [Channel]) {
        previewStream = on
        monitor?.setPreviewStream(on, channels: channels)
    }
    private let buses = BusSet()
    private var captures: [UUID: (source: String, capture: Capture, started: TimeInterval)] = [:]
    // Channels whose app plays output while the tap delivers only silence;
    // logged once per period. Not repaired: apps such as Klack keep output
    // open and silent between sounds, so this is a hint, not a fault.
    private var silent = Set<UUID>()
    // An app tap can stay silent after the app changes its audio, for example
    // Helium opening an input for a few milliseconds, although the process
    // object does not change. Silence while the app plays, just after such a
    // change, restarts the tap. Klack keeps one stream open and does not change.
    private var wasPlaying: [UUID: Bool] = [:]
    private var playStarts: [UUID: TimeInterval] = [:]
    private var seenChanges: [UUID: TimeInterval] = [:]
    private var restart = Set<UUID>()
    static let startWindow: TimeInterval = 10
    // Every statsInterval, a channel that dropped blocks or received audio at a
    // wrong rate (not 48 kHz within 2%) is logged: heard as crackle or wrong pitch.
    private var stats: [UUID: (time: TimeInterval, frames: Int, drops: Int)] = [:]
    static let statsInterval: TimeInterval = 10
    // Real playback has sound within a few I/O cycles. Called after a change
    // (onAudioChange), so the gap is about this long.
    static let startSilenceLimit: TimeInterval = 0.5
    // A rebuild while the app starts or stops its output hung coreaudiod
    // (AudioDeviceDestroyIOProcID never returned). Wait until the app's audio
    // has not changed for this long.
    static let settleTime: TimeInterval = 1
    // Marks the app taps that include pid (all app taps when nil) as changed.
    // Returns true when one matches, so the caller checks them soon.
    func audioClientChanged(_ pid: pid_t?) -> Bool {
        var matched = false
        for (id, entry) in captures {
            guard case .app(let capture) = entry.capture, capture.includes(pid) else { continue }
            capture.noteReconfiguration(); matched = true
            log.notice("Audio client change (coreaudiod log, pid \(pid.map(String.init) ?? "-", privacy: .public)): channel \(id.uuidString.prefix(8), privacy: .public)")
        }
        return matched
    }
    // Called on the listener queue when a tapped app changes its audio.
    var onAudioChange: @Sendable () -> Void = {}
    // Taps and microphones deliver input about every 10 ms, also when silent.
    // No input for this long means the capture stopped.
    static let stallLimit: TimeInterval = 2
    static let silenceLimit: TimeInterval = 30
    var droppedBlocks: Int { max(monitor?.droppedBlocks ?? 0, stream?.droppedBlocks ?? 0) }
    var receivedBlocks: Int { monitor?.receivedBlocks ?? stream?.receivedBlocks ?? 0 }
    func level(_ channel: UUID) -> Float { buses.level(channel) }
    // Estimated delay from a channel's input to each output, in seconds.
    func latency(_ channel: UUID) -> Latency? {
        guard let input = captures[channel]?.capture.latency else { return nil }
        return Latency(monitor: monitor?.latency(channel).map { input + $0 }, stream: stream?.latency(channel).map { input + $0 })
    }
    // Why a capture must restart, or nil.
    private func captureProblem(_ id: UUID, now: TimeInterval) -> String? {
        guard let entry = captures[id] else { return nil }
        guard entry.capture.isHealthy else { return "capture unhealthy" }
        if case .app(let capture) = entry.capture, capture.reconfigured, now - capture.lastChange >= Self.settleTime {
            return "app reconfigured its audio"
        }
        if restart.contains(id) { return "tap silent after an app audio change" }
        let idle = now - max(buses.activity(id).input, entry.started)
        return idle > Self.stallLimit ? "no input for \(Int(idle)) s" : nil
    }
    private func describe(_ id: UUID) -> String {
        let source = captures[id]?.source ?? "none"
        return "channel \(id.uuidString.prefix(8)) \(source); " + [monitor, stream].compactMap { $0?.state(id) }.joined(separator: "; ")
    }
    // Returns why the graph needs a repair, or nil when it is healthy. Also
    // logs a tapped app that plays output while its tap delivers only silence.
    func check() -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, entry) in captures {
            let sound = buses.activity(id).sound
            let playing = entry.capture.isPlaying
            if playing, wasPlaying[id] == false { playStarts[id] = now }
            let change = entry.capture.lastChange
            if change > (seenChanges[id] ?? 0) {
                seenChanges[id] = change; playStarts[id] = change
                log.notice("App audio changed: \(self.describe(id), privacy: .public)")
            }
            wasPlaying[id] = playing
            if let start = playStarts[id] {
                if !playing || now - start > Self.startWindow {
                    playStarts[id] = nil
                } else if now - max(sound, start) > Self.startSilenceLimit, now - entry.capture.lastChange >= Self.settleTime {
                    playStarts[id] = nil; restart.insert(id)
                    log.notice("Silent after app audio change: \(self.describe(id), privacy: .public)")
                }
            }
            if silent.contains(id) {
                guard now - sound <= Self.silenceLimit || !playing else { continue }
                silent.remove(id)
                log.notice("Silent tap ended (\(playing ? "sound" : "app stopped", privacy: .public)): \(self.describe(id), privacy: .public)")
            } else if playing, now - max(sound, entry.started) > Self.silenceLimit {
                silent.insert(id)
                log.notice("Silent tap: app plays output, tap silent for \(Int(now - max(sound, entry.started))) s: \(self.describe(id), privacy: .public)")
            }
        }
        for (id, entry) in captures where now - entry.started > Self.statsInterval {
            let frames = buses.activity(id).frames
            let drops = (monitor?.drops(id) ?? 0) + (stream?.drops(id) ?? 0)
            guard let last = stats[id] else { stats[id] = (now, frames, drops); continue }
            guard now - last.time >= Self.statsInterval else { continue }
            stats[id] = (now, frames, drops)
            let rate = Double(frames - last.frames) / (now - last.time)
            if drops > last.drops || abs(rate - 48_000) > 960 {
                log.notice("Channel stats: \(Int(rate)) frames/s, \(drops - last.drops) dropped in \(Int(now - last.time)) s: \(self.describe(id), privacy: .public)")
            }
        }
        for bus in [monitor, stream].compactMap({ $0 }) {
            if let id = bus.stuckChannel() { return "player drops all audio: \(describe(id))" }
            if !bus.isHealthy { return "\(bus.device?.name ?? "offline") bus stopped" }
        }
        for id in captures.keys {
            if let problem = captureProblem(id, now: now) { return "\(problem): \(describe(id))" }
        }
        return nil
    }

    // Brings the running graph to the settings without a full stop. Unchanged
    // channels keep capturing. Returns problems to show; never throws.
    func apply(settings: Settings, devices: [Device], defaultOutputID: AudioDeviceID? = nil, failure: @escaping (String) -> Void) async -> [String] {
        var problems: [String] = []
        let monitorDevice = settings.monitorDevice(in: devices, defaultOutputID: defaultOutputID)
        log.notice("Apply start: monitor=\(monitorDevice?.name ?? "none", privacy: .public) defaultOutput=\(defaultOutputID ?? 0) devices=\(devices.count)")
        if monitor.map({ !$0.isHealthy || $0.device?.uid != monitorDevice?.uid || $0.device?.id != monitorDevice?.id }) == true { monitor?.stop(); monitor = nil }
        if stream.map({ !$0.isHealthy }) == true { stream?.stop(); stream = nil }
        if monitor == nil { log.notice("Monitor bus rebuild") }
        if stream == nil { log.notice("Stream bus rebuild") }
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
        // The key changes with Voice Focus, so turning it on or off rebuilds the capture.
        // Digital inputs (capture cards) carry no voice to isolate.
        for channel in settings.channels where channel.voiceFocus && MicrophoneCapture.voiceFocusAvailable {
            if let source = wanted[channel.id], source.hasPrefix("mic:"),
               devices.first(where: { "mic:\($0.uid)" == source })?.isDigitalInput != true { wanted[channel.id] = source + "|voice-focus" }
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
        monitor?.setPreviewStream(previewStream, channels: [])
        monitor?.sync(settings.channels.filter { active[$0.id] != nil })
        stream?.sync(settings.channels.filter { active[$0.id] != nil })
        let now = ProcessInfo.processInfo.systemUptime
        for (id, entry) in captures {
            let problem = active[id] == entry.source ? captureProblem(id, now: now) : "source changed"
            guard let problem else { continue }
            log.notice("Capture stop (\(problem, privacy: .public)): \(self.describe(id), privacy: .public)")
            entry.capture.stop(); captures[id] = nil
            silent.remove(id); restart.remove(id); wasPlaying[id] = nil; playStarts[id] = nil; seenChanges[id] = nil; stats[id] = nil
        }
        for (id, source) in active where captures[id] == nil {
            log.notice("Capture start: channel \(id.uuidString.prefix(8), privacy: .public) \(settings.channels.first(where: { $0.id == id })?.name ?? "", privacy: .public) \(source, privacy: .public)")
            let buses = buses
            let receive: (AVAudioPCMBuffer) -> Void = { buses.feed($0, channel: id) }
            do {
                if source.hasPrefix(Channel.system) {
                    let excluded = source.dropFirst(Channel.system.count + 1).split(separator: ",").compactMap { AudioObjectID($0) }
                    let capture = ProcessCapture(receive: receive, failure: failure)
                    try await capture.start(excluding: excluded)
                    captures[id] = (source, .app(capture), ProcessInfo.processInfo.systemUptime)
                } else if source.hasPrefix("app:") {
                    let objects = Set(source.split(separator: "|").last!.split(separator: ",").compactMap { AudioObjectID($0) })
                    let members = processes.filter { objects.contains($0.id) }
                    let capture = ProcessCapture(receive: receive, failure: failure, changed: onAudioChange)
                    try await capture.start(processes: members.map(\.id), pids: members.map(\.pid).filter { $0 > 0 })
                    captures[id] = (source, .app(capture), ProcessInfo.processInfo.systemUptime)
                } else {
                    let uid = source.dropFirst(4).split(separator: "|").first.map(String.init)
                    guard let device = devices.first(where: { $0.uid == uid && $0.inputs > 0 && !$0.isLoopback }) else {
                        throw MixerError.message("The microphone is not available.")
                    }
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MixerError.message("Microphone permission was denied. Open System Settings > Privacy & Security.") }
                    let microphone = MicrophoneCapture(voiceFocus: source.hasSuffix("|voice-focus"))
                    try microphone.start(device: device, receive: receive, failure: failure)
                    captures[id] = (source, .mic(microphone), ProcessInfo.processInfo.systemUptime)
                }
            } catch {
                let name = settings.channels.first(where: { $0.id == id })?.name ?? "Channel"
                log.error("Capture start failed: \(name, privacy: .public) \(error.localizedDescription, privacy: .public)")
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        for channel in settings.channels {
            guard case .mic(let microphone)? = captures[channel.id]?.capture else { continue }
            do { try microphone.update(channel) } catch { problems.append("\(channel.name): \(error.localizedDescription)") }
        }
        log.notice("Apply done: \(problems.count) problems \(problems.joined(separator: " | "), privacy: .public)")
        return problems
    }
    func stop() {
        captures.values.forEach { $0.capture.stop() }
        previewStream = false
        captures.removeAll(); silent.removeAll(); restart.removeAll(); wasPlaying.removeAll(); playStarts.removeAll(); seenChanges.removeAll(); stats.removeAll()
        buses.set([])
        monitor?.stop(); stream?.stop()
        monitor = nil; stream = nil
    }
}
