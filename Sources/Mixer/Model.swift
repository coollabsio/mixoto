import Foundation

struct Channel: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "New channel"
    // app:<bundle ID>, mic:<device UID>, or system; empty means unassigned.
    var source = ""
    // Source name when it was chosen; shown while the source is not available.
    var sourceName = ""
    var monitor: Float = 1
    var stream: Float = 1
    var monitorMuted = false
    var streamMuted = false
    // Microphone channels only. Low Cut is a high-pass frequency in Hz (0 is off).
    var lowCut = 0
    var voiceFocus = false
    var voiceFocusStrength: Float = 0.7
    // Elgato Wave:3 hardware limiter; nil keeps the microphone's own setting.
    var clipguard: Bool?
    var monitorGain: Float { monitorMuted ? 0 : Self.safeGain(monitor) }
    var streamGain: Float { streamMuted ? 0 : Self.safeGain(stream) }
    var isSystem: Bool { source == Self.system }
    static let system = "system"
    static let lowCutFrequencies = [80, 120]
    static func safeGain(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
    // Voice Focus strength (0...1) to the isolation wet/dry percent. The mix is
    // a linear crossfade, so strength maps to 0...40 dB of noise reduction.
    static func voiceFocusMix(_ strength: Float) -> Float {
        100 * (1 - pow(10, -2 * safeGain(strength))) / (1 - pow(10, -2))
    }
}

extension Channel {
    // Settings saved by older versions lack newer keys; those keep their defaults.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func load<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws {
            value = try values.decodeIfPresent(T.self, forKey: key) ?? value
        }
        try load(.id, &id); try load(.name, &name); try load(.source, &source); try load(.sourceName, &sourceName)
        try load(.monitor, &monitor); try load(.stream, &stream)
        try load(.monitorMuted, &monitorMuted); try load(.streamMuted, &streamMuted)
        try load(.lowCut, &lowCut); try load(.voiceFocus, &voiceFocus); try load(.voiceFocusStrength, &voiceFocusStrength)
        clipguard = try values.decodeIfPresent(Bool.self, forKey: .clipguard)
    }
}

struct Settings: Codable {
    var channels: [Channel] = []
    static let defaultMonitorUID = "system-default"
    var monitorUID = ""
    var streamUID = Device.streamMixUID
    // Resolve the saved choice each time; a default selection is not a device UID.
    func monitorDevice(in devices: [Device], defaultOutputID: Device.ID?) -> Device? {
        guard !monitorUID.isEmpty else { return nil }
        return devices.first {
            $0.outputs > 0 && !$0.isLoopback &&
            (monitorUID == Self.defaultMonitorUID ? $0.id == defaultOutputID : $0.uid == monitorUID)
        }
    }
    // Read legacy settings only when the new settings file does not exist.
    static func load(from applicationSupport: URL) -> Settings {
        let current = applicationSupport.appendingPathComponent("Mixoto/settings.json")
        let legacy = applicationSupport.appendingPathComponent("OpenMixer/settings.json")
        let file = FileManager.default.fileExists(atPath: current.path) ? current : legacy
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return saved
    }
    // The permanent System channel receives all audio no other channel owns.
    mutating func ensureSystemChannel() {
        let first = channels.first(where: \.isSystem)?.id
        channels.removeAll { $0.isSystem && $0.id != first }
        if !channels.contains(where: \.isSystem) { channels.insert(Channel(name: "System", source: Channel.system, monitor: 1), at: 0) }
    }
    // Channel ID -> source for channels that can capture now, plus reasons for
    // skipped channels. One source per channel and one microphone at a time.
    func activeSources() -> (sources: [UUID: String], problems: [String]) {
        var sources: [UUID: String] = [:]
        var problems: [String] = []
        var used = Set<String>()
        for channel in channels where !channel.source.isEmpty {
            let source = channel.source
            if source == Channel.system {
                sources[channel.id] = source
            } else if !(source.hasPrefix("app:") || source.hasPrefix("mic:")) || source.count <= 4 {
                problems.append("\(channel.name): the source is not supported.")
            } else if used.contains(source) {
                problems.append("\(channel.name): this source is already used by another channel.")
            } else if source.hasPrefix("mic:"), used.contains(where: { $0.hasPrefix("mic:") }) {
                problems.append("\(channel.name): use only one microphone channel.")
            } else {
                used.insert(source); sources[channel.id] = source
            }
        }
        return (sources, problems)
    }
}

// Most audio a player may hold: two input blocks plus one output buffer and
// 5 ms for timing jitter. Anything above that is only delay. For example, a
// Bluetooth output that starts late would otherwise keep ~180 ms of old audio.
func queueLimit(block: Double, outputBuffer: Double) -> Double {
    2 * block + outputBuffer + 0.005
}

struct Latency: Equatable {
    var monitor: Double?
    var stream: Double?
}

enum MixerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Limits audio waiting in a player. Drop incoming blocks, rather than
// accumulate delay when an output starts late or cannot keep up.
final class QueueBudget {
    private let lock = NSLock()
    private var seconds: Double = 0
    let limit: Double
    init(limit: Double = 0.2) { self.limit = limit }
    func reserve(_ duration: Double, limit: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard duration.isFinite, duration > 0, seconds + duration <= min(self.limit, limit ?? self.limit) else { return false }
        seconds += duration
        return true
    }
    var queued: Double { lock.lock(); defer { lock.unlock() }; return seconds }
    func release(_ duration: Double) { lock.lock(); seconds = max(0, seconds - duration); lock.unlock() }
}
