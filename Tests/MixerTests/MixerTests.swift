import XCTest
import AVFoundation
@testable import Mixer

final class MixerTests: XCTestCase {
    @MainActor
    func testStopClearsDisplayedCountersEvenWhenAlreadyStopped() async {
        let key = "MIXOTO_SMOKE_REPORT"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "counter-test", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let store = MixerStore()
        for running in [true, false] {
            store.running = running
            store.receivedBlocks = 7461
            store.droppedBlocks = 234
            await store.stop()
            XCTAssertFalse(store.running)
            XCTAssertEqual(store.receivedBlocks, 0)
            XCTAssertEqual(store.droppedBlocks, 0)
            store.refreshCounters()
            XCTAssertEqual(store.receivedBlocks, 0)
            XCTAssertEqual(store.droppedBlocks, 0)
        }
    }
    @MainActor
    func testCounterPollingIsSuspendedDuringInstallation() {
        let key = "MIXOTO_SMOKE_REPORT"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "counter-test", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let store = MixerStore()
        store.busy = true
        // Sentinel values prove that polling does not overwrite the display.
        store.receivedBlocks = 7
        store.droppedBlocks = 2
        store.refreshCounters()
        XCTAssertEqual(store.receivedBlocks, 7)
        XCTAssertEqual(store.droppedBlocks, 2)
        store.busy = false
        store.refreshCounters()
        XCTAssertEqual(store.receivedBlocks, 0)
        XCTAssertEqual(store.droppedBlocks, 0)
    }
    func testMonitorFollowsDefaultAndPersistsTheChoice() throws {
        let headphones = Device(id: 1, uid: "headphones", name: "Headphones", inputs: 0, outputs: 2)
        let speakers = Device(id: 2, uid: "speakers", name: "Speakers", inputs: 0, outputs: 2)
        let devices = [headphones, speakers]
        var settings = Settings(monitorUID: Settings.defaultMonitorUID)
        XCTAssertEqual(settings.monitorDevice(in: devices, defaultOutputID: 1), headphones)
        XCTAssertEqual(settings.monitorDevice(in: devices, defaultOutputID: 2), speakers)
        let saved = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.monitorUID, Settings.defaultMonitorUID)
        XCTAssertEqual(saved.monitorDevice(in: devices, defaultOutputID: 2), speakers)
        settings.monitorUID = "headphones"
        XCTAssertEqual(settings.monitorDevice(in: devices, defaultOutputID: 2), headphones)
        XCTAssertNil(settings.monitorDevice(in: [speakers], defaultOutputID: 2))
        settings.monitorUID = ""
        XCTAssertNil(settings.monitorDevice(in: devices, defaultOutputID: 1))
    }
    func testDefaultMonitorRefusesMissingInputOnlyAndLoopbackDevices() {
        let settings = Settings(monitorUID: Settings.defaultMonitorUID)
        let microphone = Device(id: 1, uid: "mic", name: "Mic", inputs: 1, outputs: 0)
        let stream = Device(id: 2, uid: Device.streamMixUID, name: "Custom name", inputs: 2, outputs: 2)
        let blackhole = Device(id: 3, uid: "blackhole", name: "BlackHole", inputs: 2, outputs: 2)
        let legacy = Device(id: 4, uid: "local.openmixer.stream-mix", name: "Custom legacy name", inputs: 2, outputs: 2)
        let devices = [microphone, stream, blackhole, legacy]
        for id: Device.ID? in [nil, 0, 1, 2, 3, 4, 99] {
            XCTAssertNil(settings.monitorDevice(in: devices, defaultOutputID: id))
        }
    }
    @MainActor
    func testUnavailableDefaultMonitorDoesNotOpenHardware() async {
        let router = AudioRouter()
        let problems = await router.apply(settings: Settings(monitorUID: Settings.defaultMonitorUID), devices: [], failure: { _ in })
        XCTAssertTrue(problems.contains { $0.contains("default system output is unavailable") })
        XCTAssertEqual(router.receivedBlocks, 0)
        router.stop()
    }
    func testNewChannelsStartAtFullVolume() {
        let channel = Channel()
        XCTAssertEqual(channel.monitor, 1)
        XCTAssertEqual(channel.stream, 1)
        XCTAssertEqual(channel.monitorGain, 1)
        XCTAssertEqual(channel.streamGain, 1)
    }
    func testIndependentControls() {
        var channel = Channel(monitor: 0.3, stream: 0.8)
        channel.monitorMuted = true
        XCTAssertEqual(channel.monitorGain, 0)
        XCTAssertEqual(channel.streamGain, 0.8)
        channel.monitorMuted = false
        channel.streamMuted = true
        XCTAssertEqual(channel.monitorGain, 0.3)
        XCTAssertEqual(channel.streamGain, 0)
    }
    func testGainClamping() {
        XCTAssertEqual(Channel.safeGain(.nan), 0)
        XCTAssertEqual(Channel.safeGain(.infinity), 0)
        XCTAssertEqual(Channel.safeGain(-2), 0)
        XCTAssertEqual(Channel.safeGain(2), 1)
    }
    func testPersistence() throws {
        let channel = Channel(name: "Music", source: "app:test", monitor: 0.2, stream: 0.9, streamMuted: true)
        let settings = Settings(channels: [channel], monitorUID: "headphones", streamUID: "loopback")
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.channels, settings.channels)
        XCTAssertEqual(decoded.monitorUID, "headphones")
        XCTAssertEqual(decoded.streamUID, "loopback")
    }
    func testLegacyDriverIsNotASelectableSourceOrMixotoOutput() {
        let legacy = Device(id: 1, uid: "local.openmixer.stream-mix", name: "Custom name", inputs: 2, outputs: 2)
        XCTAssertTrue(legacy.isLoopback)
        XCTAssertFalse(legacy.isStreamMix)
        XCTAssertEqual(Device.streamMixUID, "local.mixoto.stream-mix")
    }
    func testRenamedSettingsPreferCurrentAndRetainLegacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("OpenMixer/settings.json")
        let current = directory.appendingPathComponent("Mixoto/settings.json")
        for file in [legacy, current] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        XCTAssertTrue(Settings.load(from: directory).channels.isEmpty)
        let channel = Channel(name: "Music", source: "app:test", monitor: 0.2, stream: 0.9)
        try JSONEncoder().encode(Settings(channels: [channel], monitorUID: "headphones")).write(to: legacy)
        XCTAssertEqual(Settings.load(from: directory).channels, [channel])
        XCTAssertEqual(Settings.load(from: directory).monitorUID, "headphones")
        try JSONEncoder().encode(Settings(monitorUID: "current")).write(to: current)
        XCTAssertEqual(Settings.load(from: directory).monitorUID, "current")
        try Data("invalid".utf8).write(to: current)
        XCTAssertTrue(Settings.load(from: directory).channels.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
    func testActiveSourcesSkipInvalidChannels() {
        let app = Channel(source: "app:test")
        let duplicate = Channel(source: "app:test")
        let micA = Channel(source: "mic:a"), micB = Channel(source: "mic:b")
        let bad = Channel(source: "other:x"), empty = Channel(source: "app:"), unassigned = Channel()
        let (sources, problems) = Settings(channels: [app, duplicate, micA, micB, bad, empty, unassigned]).activeSources()
        XCTAssertEqual(sources, [app.id: "app:test", micA.id: "mic:a"])
        XCTAssertEqual(problems.count, 4)
    }
    func testSystemChannelIsPermanentAndActive() {
        var settings = Settings(channels: [Channel(source: "app:a"), Channel(source: "system"), Channel(source: "system")])
        settings.ensureSystemChannel()
        XCTAssertEqual(settings.channels.filter(\.isSystem).count, 1)
        var empty = Settings()
        empty.ensureSystemChannel()
        XCTAssertEqual(empty.channels.map(\.source), ["system"])
        XCTAssertEqual(empty.activeSources().sources.values.first, "system")
    }
    func testPeakLevel() {
        let buffer = constantBuffer(0.25, frames: 64)
        buffer.floatChannelData![1][10] = -0.9
        XCTAssertEqual(BusSet.peak(buffer), 0.9)
        let buses = BusSet(), id = UUID()
        buses.feed(buffer, channel: id)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(buses.level(id, at: now), 0.9, accuracy: 0.01)
        // 30 dB per second: one second later the level is about 0.9 × 10^-1.5.
        XCTAssertEqual(buses.level(id, at: now + 1), 0.9 * pow(10, -1.5), accuracy: 0.001)
        XCTAssertEqual(buses.level(UUID()), 0)
    }
    func testHelperProcessesBelongToApp() {
        XCTAssertTrue(Devices.belongs("net.imput.helium", to: "net.imput.helium"))
        XCTAssertTrue(Devices.belongs("net.imput.helium.helper", to: "net.imput.helium"))
        XCTAssertFalse(Devices.belongs("net.imput.heliumx", to: "net.imput.helium"))
        XCTAssertFalse(Devices.belongs("com.apple.WebKit.GPU", to: "com.apple.Safari"))
    }
    func testQueueBudget() {
        let budget = QueueBudget(limit: 0.1)
        XCTAssertFalse(budget.reserve(.nan))
        XCTAssertFalse(budget.reserve(-1))
        XCTAssertTrue(budget.reserve(0.06))
        XCTAssertFalse(budget.reserve(0.06))
        budget.release(0.06)
        XCTAssertTrue(budget.reserve(0.06))
    }
    func testDevicesCanBeEnumerated() throws {
        let devices = try Devices.list()
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count)
        for device in devices { XCTAssertFalse(device.name.isEmpty); XCTAssertFalse(device.uid.isEmpty) }
        print("Devices: \(devices.map { "\($0.name) [in=\($0.inputs), out=\($0.outputs)]" }.joined(separator: "; "))")
    }
    private func constantBuffer(_ value: Float, frames: AVAudioFrameCount = 4096) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: OutputBus.format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = value }
        }
        return buffer
    }
    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        // Ignore engine startup ramps in the first half of this block.
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0] + Int(buffer.frameLength / 2), count: Int(buffer.frameLength / 2)))
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
    func testActualGraphIndependentMixesAndMutes() throws {
        var channel = Channel(source: "app:test", monitor: 0.25, stream: 0.75)
        let monitor = try OutputBus(device: nil, channels: [channel], monitor: true)
        let stream = try OutputBus(device: nil, channels: [channel], monitor: false)
        defer { monitor.stop(); stream.stop() }
        let buffer = constantBuffer(0.4)
        monitor.feed(buffer, channel: channel.id); stream.feed(buffer, channel: channel.id)
        XCTAssertEqual(rms(try monitor.renderOffline(frames: 4096)), 0.1, accuracy: 0.002)
        XCTAssertEqual(rms(try stream.renderOffline(frames: 4096)), 0.3, accuracy: 0.002)
        channel.monitorMuted = true
        monitor.update(channel, monitor: true)
        monitor.feed(buffer, channel: channel.id); stream.feed(buffer, channel: channel.id)
        XCTAssertEqual(rms(try monitor.renderOffline(frames: 4096)), 0, accuracy: 0.002)
        XCTAssertEqual(rms(try stream.renderOffline(frames: 4096)), 0.3, accuracy: 0.002)
        // Offline rendering has no hardware playback clock. dataPlayedBack callbacks
        // need not complete before the next render; use fresh graphs for this state.
        channel.monitorMuted = false; channel.streamMuted = true
        let nextMonitor = try OutputBus(device: nil, channels: [channel], monitor: true)
        let nextStream = try OutputBus(device: nil, channels: [channel], monitor: false)
        defer { nextMonitor.stop(); nextStream.stop() }
        nextMonitor.feed(buffer, channel: channel.id); nextStream.feed(buffer, channel: channel.id)
        XCTAssertEqual(rms(try nextMonitor.renderOffline(frames: 4096)), 0.1, accuracy: 0.002)
        XCTAssertEqual(rms(try nextStream.renderOffline(frames: 4096)), 0, accuracy: 0.002)
    }
    func testActualGraphSumsChannels() throws {
        let a = Channel(source: "app:a", monitor: 0.2)
        let b = Channel(source: "app:b", monitor: 0.5)
        let bus = try OutputBus(device: nil, channels: [a, b], monitor: true)
        defer { bus.stop() }
        bus.feed(constantBuffer(0.4), channel: a.id)
        bus.feed(constantBuffer(0.4), channel: b.id)
        XCTAssertEqual(rms(try bus.renderOffline(frames: 4096)), 0.28, accuracy: 0.002)
    }
    func testStreamMixIncludesAllUnmutedChannels() throws {
        let a = Channel(source: "app:a", monitor: 0.9, stream: 0.2, monitorMuted: true)
        let b = Channel(source: "app:b", monitor: 0.9, stream: 0.5)
        let excluded = Channel(source: "app:c", stream: 1, streamMuted: true)
        let bus = try OutputBus(device: nil, channels: [a, b, excluded], monitor: false)
        defer { bus.stop() }
        for channel in [a, b, excluded] { bus.feed(constantBuffer(0.4), channel: channel.id) }
        XCTAssertEqual(rms(try bus.renderOffline(frames: 4096)), 0.28, accuracy: 0.002)
    }
    func testNativeStreamDeviceUsesStableUID() {
        let native = Device(id: 1, uid: Device.streamMixUID, name: "Renamed device", inputs: 2, outputs: 2)
        let other = Device(id: 2, uid: "other", name: "Mixoto Stream Mix", inputs: 2, outputs: 2)
        XCTAssertTrue(native.isStreamMix)
        XCTAssertTrue(native.isLoopback)
        XCTAssertFalse(other.isStreamMix)
        XCTAssertEqual(Settings().streamUID, Device.streamMixUID)
    }
    @MainActor
    func testMissingVirtualDriverStartsNoCapture() async {
        let router = AudioRouter()
        let settings = Settings(channels: [Channel(source: "app:not.running")])
        let problems = await router.apply(settings: settings, devices: [], failure: { _ in })
        XCTAssertTrue(problems[0].contains("Install the virtual device"))
        XCTAssertTrue(problems.contains { $0.contains("waiting for the app to play audio") })
        XCTAssertEqual(router.receivedBlocks, 0)
        router.stop()
    }
    func testActualGraphAddsAndRemovesChannelsWhileRunning() throws {
        let a = Channel(source: "app:a", monitor: 0.5)
        let b = Channel(source: "app:b", monitor: 0.25)
        let bus = try OutputBus(device: nil, channels: [a], monitor: true)
        defer { bus.stop() }
        bus.feed(constantBuffer(0.4), channel: b.id) // Not added yet: ignored.
        XCTAssertEqual(bus.receivedBlocks, 0)
        bus.sync([a, b])
        bus.feed(constantBuffer(0.4), channel: b.id)
        XCTAssertEqual(rms(try bus.renderOffline(frames: 4096)), 0.1, accuracy: 0.002)
        bus.sync([b])
        bus.feed(constantBuffer(0.4), channel: a.id) // Removed: ignored.
        XCTAssertEqual(bus.receivedBlocks, 1)
    }
    func testInstallerQuotesPathsWithoutShellExpansion() throws {
        let path = #"space ' quote \ " double $HOME $(printf injected); end"#
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + DriverInstaller.shellQuote(path)]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), path)
        XCTAssertEqual(DriverInstaller.appleScript("echo \"a\\b\""), "do shell script \"echo \\\"a\\\\b\\\"\" with administrator privileges")
    }
    func testActualGraphBoundsPendingAudio() throws {
        let channel = Channel(source: "app:test")
        let bus = try OutputBus(device: nil, channels: [channel], monitor: true)
        defer { bus.stop() }
        for _ in 0..<10 { bus.feed(constantBuffer(0.1), channel: channel.id) }
        XCTAssertEqual(bus.droppedBlocks, 8) // Two 85.3 ms blocks fit in 200 ms.
    }
    func testCaptureBufferCopyPlanarAndInterleaved() throws {
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            pcm.frameLength = 128
            for frame in 0..<128 {
                if interleaved {
                    pcm.floatChannelData![0][frame * 2] = 0.2
                    pcm.floatChannelData![0][frame * 2 + 1] = -0.4
                } else {
                    pcm.floatChannelData![0][frame] = 0.2
                    pcm.floatChannelData![1][frame] = -0.4
                }
            }
            let normalizer = try PCMNormalizer(format: format)
            let copied = try XCTUnwrap(normalizer.copy(pcm.audioBufferList))
            XCTAssertFalse(copied.format.isInterleaved)
            XCTAssertEqual(copied.frameLength, 128)
            XCTAssertEqual(copied.floatChannelData![0][127], 0.2)
            XCTAssertEqual(copied.floatChannelData![1][127], -0.4)
        }
    }
    func testMonoMicrophoneConversion() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        source.frameLength = 512
        for frame in 0..<512 { source.floatChannelData![0][frame] = 0.25 }
        let normalizer = try PCMNormalizer(format: format)
        let result = try XCTUnwrap(normalizer.copy(source.audioBufferList))
        XCTAssertEqual(result.frameLength, 512)
        XCTAssertEqual(result.floatChannelData![0][511], 0.25)
        XCTAssertEqual(result.floatChannelData![1][511], 0.25)
    }
    func testSampleRateConversion() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        source.frameLength = 4410
        for channel in 0..<2 {
            for frame in 0..<4410 { source.floatChannelData![channel][frame] = 0.25 }
        }
        let normalizer = try PCMNormalizer(format: format)
        let result = try XCTUnwrap(normalizer.copy(source.audioBufferList))
        XCTAssertEqual(result.format.sampleRate, 48_000)
        // The converter keeps its normal priming state. Startup can produce a
        // shorter block; steady-state blocks must preserve the rate ratio.
        XCTAssertGreaterThan(result.frameLength, 4000)
        XCTAssertEqual(result.floatChannelData![0][4000], 0.25, accuracy: 0.001)
        var total = Int(result.frameLength)
        for _ in 1..<20 {
            let next = try XCTUnwrap(normalizer.copy(source.audioBufferList))
            total += Int(next.frameLength)
            XCTAssertEqual(next.floatChannelData![1][4000], 0.25, accuracy: 0.001)
        }
        XCTAssertEqual(Double(total), 20 * 4800, accuracy: 512)
    }
}
