import SwiftUI
import AppKit
import CoreAudio

@MainActor
final class MixerStore: ObservableObject {
    @Published var settings: Settings
    @Published var devices: [Device] = []
    @Published var defaultOutputID: AudioDeviceID?
    @Published var apps: [RunningApp] = []
    @Published var running = false
    @Published var busy = false
    @Published var message = ""
    @Published var droppedBlocks = 0
    @Published var receivedBlocks = 0
    // Each publish updates the whole window, so counters refresh only while
    // the debug popover shows them.
    var countersVisible = false
    @Published var latencies: [UUID: Latency] = [:]
    // Hardware settings of each Elgato Wave:3 that a channel uses, by device UID.
    @Published var wave3: [String: Wave3.State] = [:]
    private let router = AudioRouter()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var wave3Timer: Timer?
    private let wave3Queue = DispatchQueue(label: "Mixoto.wave3")
    private var readingWave3 = false
    private var applying = false
    private var pending = false
    private let file: URL
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mixoto/settings.json")
        let smoke = ProcessInfo.processInfo.environment["MIXOTO_SMOKE_REPORT"] != nil
        if smoke {
            settings = Settings(channels: [Channel(name: "Microphone"), Channel(name: "Application")])
        } else { settings = Settings.load(from: file.deletingLastPathComponent().deletingLastPathComponent()) }
        // Retain saved channels/gains but replace the old OBS/BlackHole route.
        settings.streamUID = Device.streamMixUID
        settings.ensureSystemChannel()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.repairIfNeeded() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.countersVisible { self.refreshCounters() }
                await self.repairIfNeeded()
            }
        }
        // Common modes: keep reading while a control or menu tracks the mouse.
        let wave3Timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWave3() }
        }
        RunLoop.main.add(wave3Timer, forMode: .common)
        self.wave3Timer = wave3Timer
        // Keep device and application lists current. A new audio process can
        // also let a waiting application channel start.
        Devices.observe(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in Task { @MainActor in self?.refreshDevices() } }
        Devices.observe(kAudioHardwarePropertyDevices) { [weak self] in Task { @MainActor in self?.refreshDevices() } }
        Devices.observe(kAudioHardwarePropertyProcessObjectList) { [weak self] in Task { @MainActor in self?.refreshApps() } }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshApps() } }
        }
        refreshDevices()
        refreshApps()
        // The smoke test must not start audio or request recording access.
        if !smoke { Task { await start() } }
    }
    func save() {
        guard ProcessInfo.processInfo.environment["MIXOTO_SMOKE_REPORT"] == nil else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: file, options: .atomic)
        } catch { message = "Cannot save settings: \(error.localizedDescription)" }
    }
    func refreshCounters() {
        guard !busy else { return }
        droppedBlocks = router.droppedBlocks
        receivedBlocks = router.receivedBlocks
        latencies = Dictionary(uniqueKeysWithValues: settings.channels.compactMap { channel in router.latency(channel.id).map { (channel.id, $0) } })
    }
    // Reads 10 times per second, so touch mute and dial changes show at once.
    // A read takes under 1 ms; it runs off the main thread in case USB stalls.
    // A failed read keeps the last state, for example while Wave Link has the
    // controls open.
    func refreshWave3() {
        guard !busy, !readingWave3, ProcessInfo.processInfo.environment["MIXOTO_SMOKE_REPORT"] == nil else { return }
        let sources = Set(settings.channels.map(\.source))
        let targets = devices.filter { Wave3.serial($0) != nil && sources.contains("mic:\($0.uid)") }
        let previous = wave3
        readingWave3 = true
        wave3Queue.async { [weak self] in
            var states: [String: Wave3.State] = [:]
            for device in targets { states[device.uid] = (try? Wave3.state(device)) ?? previous[device.uid] }
            Task { @MainActor in
                guard let self else { return }
                self.readingWave3 = false
                if states != self.wave3 { self.wave3 = states }
            }
        }
    }
    func refreshDevices() {
        defaultOutputID = try? Devices.defaultOutputID()
        do { devices = try Devices.list() } catch { message = error.localizedDescription }
        if running { Task { await apply() } }
    }
    func refreshApps() {
        apps = RunningApp.list()
        if running { Task { await apply() } }
    }
    func start() async {
        guard !running, !busy else { return }
        running = true
        await apply()
    }
    func stop() async {
        running = false
        router.stop()
        droppedBlocks = 0
        receivedBlocks = 0
        latencies = [:]
        message = ""
    }
    // Serializes graph changes. A change during an apply runs once more afterwards.
    func apply() async {
        guard running, !busy else { return }
        if applying { pending = true; return }
        applying = true; defer { applying = false }
        repeat {
            pending = false
            let problems = await router.apply(settings: settings, devices: devices, defaultOutputID: defaultOutputID) { [weak self] error in
                Task { @MainActor in self?.message = "Capture stopped: \(error)" }
            }
            guard running else { router.stop(); return }
            message = problems.first ?? ""
        } while pending
    }
    private func repairIfNeeded() async {
        guard running, !applying, !router.isHealthy else { return }
        if let list = try? Devices.list() { devices = list }
        defaultOutputID = try? Devices.defaultOutputID()
        await apply()
    }
    func changed() {
        save()
        if running { Task { await apply() } }
    }
    func level(_ channel: UUID) -> Float { router.level(channel) }
    func renameStreamMix(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device = devices.first(where: \.isStreamMix), !name.isEmpty, name != device.name else { return }
        do {
            try Devices.rename(device, to: String(name.prefix(64)))
            message = ""
        } catch { message = error.localizedDescription }
        refreshDevices()
    }
    func installVirtualDevice() async {
        guard !busy else { return }
        guard let resources = Bundle.main.resourceURL else { message = "Build and open the app bundle to install the driver."; return }
        let driver = resources.appendingPathComponent("MixotoAudio.driver")
        let script = resources.appendingPathComponent("install-driver.sh")
        guard FileManager.default.fileExists(atPath: driver.path), FileManager.default.fileExists(atPath: script.path) else {
            message = "Driver installer is not bundled. Run scripts/build-app.sh, then open the built app."; return
        }
        let wasRunning = running
        await stop()
        busy = true
        message = "macOS will ask for administrator access. System audio stops for a few seconds while Core Audio restarts."
        do {
            try await DriverInstaller.install(driver: driver, script: script)
            try? await Task.sleep(for: .seconds(2))
            if let list = try? Devices.list() { devices = list }
            defaultOutputID = try? Devices.defaultOutputID()
            message = devices.contains(where: \.isStreamMix) ? "Virtual device installed and loaded."
                : "Virtual device installed, but Core Audio has not loaded it. Restart macOS."
        } catch { message = error.localizedDescription }
        busy = false
        if wasRunning { await start() }
    }
}

@main
struct MixotoApp: App {
    @NSApplicationDelegateAdaptor(MixerAppDelegate.self) private var appDelegate
    @StateObject private var store = MixerStore()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        Window("Mixoto", id: "mixer") {
            MixerView(store: store)
                .frame(minWidth: 800, minHeight: 580)
                .task { await SmokeCheck.runIfRequested(store: store) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates || store.busy)
                Toggle("Check for Updates Automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticChecks($0) }
                )).disabled(!updater.isAvailable)
                Button("Reinstall Virtual Device…") { Task { await store.installVirtualDevice() } }.disabled(store.busy)
            }
        }
        MenuBarExtra {
            MixerMenuBar()
        } label: {
            Image(nsImage: MixerMenuBar.icon).accessibilityLabel("Mixoto")
        }
    }
}

struct MixerMenuBar: View {
    @Environment(\.openWindow) private var openWindow

    // The same three faders as Resources/AppIcon.svg, without its tile/shadow.
    // A template lets macOS choose the correct color for the menu bar.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for (x, knobY) in [(3.0, 8.0), (7.0, 4.0), (11.0, 6.0)] {
                func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NSRect {
                    NSRect(x: (x - 2) * 1.5 + 0.75, y: (y - 3) * 1.5 + 2.25,
                           width: width * 1.5, height: height * 1.5)
                }
                NSBezierPath(rect: rect(x, 3, 1, 9)).fill()
                NSBezierPath(rect: rect(x - 1, knobY, 3, 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mixoto"
        return image
    }()

    var body: some View {
        Button("Show Mixoto") {
            openWindow(id: "mixer")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Mixoto…") { NSApplication.shared.terminate(nil) }
    }
}

struct MixerView: View {
    @ObservedObject var store: MixerStore
    @State private var showingDebugInfo = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack {
                HStack {
                    Text("Monitor headphones").frame(width: 170, alignment: .leading)
                    Picker("Monitor headphones", selection: $store.settings.monitorUID) {
                        Text("Off — Stream Mix only").tag("")
                        Text("Default system output").tag(Settings.defaultMonitorUID)
                        ForEach(store.devices.filter { $0.outputs > 0 && !$0.isLoopback }) { Text($0.name).tag($0.uid) }
                        if !store.settings.monitorUID.isEmpty && store.settings.monitorUID != Settings.defaultMonitorUID && !store.devices.contains(where: { $0.uid == store.settings.monitorUID }) {
                            Text("Saved device unavailable").tag(store.settings.monitorUID)
                        }
                    }.labelsHidden().flexibleButtonWidth().frame(width: 280)
                    Spacer()
                    // Running state and Start/Stop control in one: green runs, red is stopped.
                    Button { Task { if store.running { await store.stop() } else { await store.start() } } } label: {
                        Color.clear.frame(width: 16, height: 16)
                            .glass(tint: store.running ? .green : .red, interactive: true, in: Circle())
                            .padding(2).contentShape(Circle())
                    }
                    .buttonStyle(.plain).disabled(store.busy).keyboardShortcut(.space, modifiers: [])
                    .help(store.running ? "Running — click to stop" : "Stopped — click to start")
                    .accessibilityLabel(store.running ? "Running. Stop mixer" : "Stopped. Start mixer")
                }
                HStack {
                    Text("Stream Mix virtual input").frame(width: 170, alignment: .leading)
                    // Loaded: status only; reinstall is in the Mixoto menu.
                    if let device = store.devices.first(where: \.isStreamMix) {
                        StreamMixName(current: device.name) { store.renameStreamMix($0) }
                        Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.multicolor).help("Installed and loaded")
                    } else {
                        Text(FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/MixotoAudio.driver") ? "Installed, not loaded" : "Not installed")
                            .foregroundStyle(.secondary)
                        Button("Install…") { Task { await store.installVirtualDevice() } }.glassButton(prominent: true)
                    }
                    Spacer()
                }
            }.disabled(store.busy)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach($store.settings.channels) { $channel in strip($channel) }
                    Button { store.settings.channels.append(Channel()); store.save() } label: {
                        Image(systemName: "plus").font(.system(size: 28, weight: .light))
                            .frame(width: 120).frame(maxHeight: .infinity)
                            .panel()
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add channel").accessibilityLabel("Add channel")
                    .disabled(store.busy)
                }
                .padding(.bottom, 8)
            }
            HStack {
                Text(store.message).textSelection(.enabled)
                Spacer()
                Button { showingDebugInfo.toggle() } label: {
                    Image(systemName: "ladybug")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show debug information")
                .accessibilityLabel("Show debug information")
                .popover(isPresented: $showingDebugInfo, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Debug information").font(.headline)
                        Text("Captured: \(store.receivedBlocks)").monospacedDigit()
                        Text("Dropped blocks: \(store.droppedBlocks)").monospacedDigit()
                        let latent = store.settings.channels.filter { store.latencies[$0.id] != nil }
                        if !latent.isEmpty {
                            Divider()
                            Text("Latency, input to output").font(.subheadline.bold())
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                GridRow { Text(""); Text("Monitor"); Text("Stream") }.foregroundStyle(.secondary)
                                ForEach(latent) { channel in
                                    let latency = store.latencies[channel.id]
                                    GridRow { Text(channel.name); Text(Self.milliseconds(latency?.monitor)); Text(Self.milliseconds(latency?.stream)) }
                                }
                            }.monospacedDigit()
                            Text("Estimate: device delays, effects, and queued audio. Updates each second.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .frame(minWidth: 220, alignment: .leading)
                    .textSelection(.enabled)
                    .onAppear { store.countersVisible = true; store.refreshCounters() }
                    .onDisappear { store.countersVisible = false }
                }
            }.font(.callout)
        }
        .padding(20)
        .onChange(of: store.settings.channels) { _, _ in store.changed() }
        .onChange(of: store.settings.monitorUID) { _, _ in store.changed() }
        .onChange(of: store.settings.streamUID) { _, _ in store.save() }
    }
    static func milliseconds(_ seconds: Double?) -> String { seconds.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "—" }
    private func sourceName(_ source: String) -> String? {
        if source.hasPrefix("app:") { return store.apps.first { "app:\($0.bundleIdentifier)" == source }?.name }
        if source.hasPrefix("mic:") { return store.devices.first { "mic:\($0.uid)" == source }?.name }
        return nil
    }
    private var availableSources: Set<String> {
        Set(store.devices.filter { $0.inputs > 0 && !$0.isLoopback }.map { "mic:\($0.uid)" } + store.apps.map { "app:\($0.bundleIdentifier)" })
    }
    private func strip(_ channel: Binding<Channel>) -> some View {
        let value = channel.wrappedValue
        return VStack(spacing: 8) {
            TextField("Name", text: channel.name).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            if value.isSystem {
                Text("All other audio").font(.callout).foregroundStyle(.secondary).frame(height: 22)
            } else {
                Picker("Source", selection: Binding(get: { channel.wrappedValue.source }, set: { source in
                    // Rename only default or automatic names; keep names the user typed.
                    let name = channel.wrappedValue.name
                    if name.isEmpty || name == Channel().name || name == sourceName(channel.wrappedValue.source) {
                        channel.wrappedValue.name = sourceName(source) ?? Channel().name
                    }
                    channel.wrappedValue.source = source
                })) {
                    Text("Unassigned").tag("")
                    ForEach(store.devices.filter { $0.inputs > 0 && !$0.isLoopback }) { Text("Mic: \($0.name)").tag("mic:\($0.uid)") }
                    ForEach(store.apps, id: \.bundleIdentifier) { Text("App: \($0.name)").tag("app:\($0.bundleIdentifier)") }
                    if !value.source.isEmpty && !availableSources.contains(value.source) { Text("Saved source — not available").tag(value.source) }
                }.labelsHidden().flexibleButtonWidth()
            }
            HStack(spacing: 14) {
                fader("Monitor", gain: channel.monitor, muted: channel.monitorMuted, level: { store.level(value.id) * value.monitorGain })
                fader("Stream", gain: channel.stream, muted: channel.streamMuted, level: { store.level(value.id) * value.streamGain })
            }
            if value.isSystem {
                Color.clear.frame(height: 22)
            } else {
                HStack {
                    if value.source.hasPrefix("mic:") {
                        let device = store.devices.first { "mic:\($0.uid)" == value.source }
                        let wave3 = device.flatMap { store.wave3[$0.uid] }
                        if wave3?.muted == true {
                            Image(systemName: "mic.slash.fill").foregroundStyle(.red)
                                .help("Muted on the Wave:3").accessibilityLabel("Muted on the Wave:3")
                        }
                        MicrophoneEffects(channel: channel, device: device, wave3: wave3)
                    }
                    Button(role: .destructive) { store.settings.channels.removeAll { $0.id == value.id }; store.save() } label: { Image(systemName: "trash") }
                        .glassButton().help("Remove channel")
                }
            }
        }
        .padding(10)
        .frame(width: 170)
        .panel()
    }
    private func fader(_ label: String, gain: Binding<Float>, muted: Binding<Bool>, level: @escaping () -> Float) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                VerticalFader(value: gain).accessibilityLabel("\(label) volume")
                LevelMeter(level: level, active: store.running)
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            Text("\(Int(Channel.safeGain(gain.wrappedValue) * 100))%").font(.caption).monospacedDigit()
            Button("Mute") { muted.wrappedValue.toggle() }
                .glassButton(prominent: muted.wrappedValue).tint(muted.wrappedValue ? .red : nil).controlSize(.small)
                .accessibilityLabel("\(label) mute").accessibilityAddTraits(muted.wrappedValue ? .isSelected : [])
        }
    }
}

// Microphone settings: Clipguard on an Elgato Wave:3, plus Low Cut and
// Voice Focus, which Mixoto applies to the captured audio.
struct MicrophoneEffects: View {
    @Binding var channel: Channel
    let device: Device?
    let wave3: Wave3.State?
    @State private var showing = false
    private var isWave3: Bool { device.flatMap(Wave3.serial) != nil }
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "slider.horizontal.3") }
            .glassButton(prominent: channel.lowCut > 0 || channel.voiceFocus)
            .help("Microphone effects").accessibilityLabel("Microphone effects")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Form {
                    if isWave3 {
                        Section("Wave:3 hardware") {
                            // Show the microphone's own setting until the user chooses one.
                            Toggle("Clipguard", isOn: Binding(get: { channel.clipguard ?? wave3?.clipguard ?? false }, set: { channel.clipguard = $0 }))
                                .help("The microphone lowers its gain to prevent clipping.")
                            if let wave3 {
                                LabeledContent("Microphone") { Text(wave3.muted ? "Muted" : "On").foregroundStyle(wave3.muted ? .red : .secondary) }
                                LabeledContent("Gain", value: String(format: "%.1f dB", wave3.gain))
                                LabeledContent("Headphones", value: wave3.headphonesMuted ? "Muted" : String(format: "%.1f dB", wave3.headphones))
                                LabeledContent("Monitor mix", value: "Mic \(Int((100 - wave3.computerMix).rounded()))% · Computer \(Int(wave3.computerMix.rounded()))%")
                                LabeledContent("Dial controls", value: wave3.dial)
                                LabeledContent("Hardware low cut", value: wave3.lowCut ? "On" : "Off")
                            } else {
                                Text("Cannot read the Wave:3 settings.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Software effects") {
                        Picker("Low Cut", selection: $channel.lowCut) {
                            Text("Off").tag(0)
                            ForEach(Channel.lowCutFrequencies, id: \.self) { Text("\($0) Hz").tag($0) }
                        }.help("Removes rumble and other low-frequency sound.")
                        if MicrophoneCapture.voiceFocusAvailable {
                            Toggle("Voice Focus", isOn: $channel.voiceFocus)
                            Slider(value: $channel.voiceFocusStrength, in: 0...1) { Text("Strength") }
                                minimumValueLabel: { Text("Weak") } maximumValueLabel: { Text("Strong") }
                                .disabled(!channel.voiceFocus)
                            Text("Removes background noise from your voice. Adds about 60 ms of delay.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped).frame(width: 340)
            }
    }
}

// Vertical volume control, 0 at the bottom and 1 at the top.
struct VerticalFader: View {
    @Binding var value: Float
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height, knob: CGFloat = 14
            let fraction = CGFloat(Channel.safeGain(value))
            ZStack(alignment: .bottom) {
                Capsule().fill(.primary.opacity(0.12)).frame(width: 6)
                Capsule().fill(Color.accentColor).frame(width: 6, height: (height - knob) * fraction + knob / 2)
                Color.clear.frame(width: 24, height: knob)
                    .glass(tint: .white.opacity(0.3), interactive: true, in: Capsule())
                    .offset(y: -(height - knob) * fraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = (height - knob / 2 - drag.location.y) / max(1, height - knob)
                value = Float(min(1, max(0, position)))
            })
        }
        .frame(width: 26)
        .accessibilityElement()
        .accessibilityValue("\(Int(Channel.safeGain(value) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

// Peak level after this mix's gain and mute, -60 to 0 dBFS. A layer reads
// the audio-side level 30 times per second, outside SwiftUI: a SwiftUI
// animation here updated the whole window each frame.
struct LevelMeter: NSViewRepresentable {
    let level: () -> Float
    var active = true
    func makeNSView(context: Context) -> LevelMeterView { LevelMeterView() }
    func updateNSView(_ view: LevelMeterView, context: Context) {
        view.level = level
        view.active = active
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LevelMeterView, context: Context) -> CGSize? {
        CGSize(width: 6, height: proposal.height ?? 140)
    }
}

final class LevelMeterView: NSView {
    var level: () -> Float = { 0 }
    var active = true { didSet { link?.isPaused = !active; if !active { show(0) } } }
    private let bar = CALayer()
    private var link: CADisplayLink?
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Level")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    // Also runs when the appearance changes; the track color depends on it.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = bounds.width / 2
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.isPaused = !active
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick() { show(active ? level() : 0) }
    private func show(_ value: Float) {
        let db = 20 * log10(max(value, 0.000_001))
        let height = bounds.height * CGFloat(min(1, max(0, (db + 60) / 60)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        bar.cornerRadius = bounds.width / 2
        bar.backgroundColor = (db > -3 ? NSColor.systemRed : db > -12 ? .systemYellow : .systemGreen).cgColor
        CATransaction.commit()
    }
    override func accessibilityValue() -> Any? {
        let value = active ? level() : 0
        return value > 0.001 ? "\(Int(20 * log10(value))) dB" : "silent"
    }
    deinit { link?.invalidate() }
}

// Liquid Glass on macOS 26 and later; a flat fill on macOS 15.
extension View {
    // Large areas use a flat fill: Liquid Glass behind every channel strip
    // cost about 8 MB of graphics memory.
    func panel() -> some View {
        background(RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.06)))
    }
    @ViewBuilder func glass<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(shape.fill(tint ?? Color.primary.opacity(0.08)))
        }
    }
    // macOS 26 sizes pop-up menus to their content; fill the given width instead.
    @ViewBuilder func flexibleButtonWidth() -> some View {
        if #available(macOS 26, *) { self.buttonSizing(.flexible) } else { self }
    }
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

// Device name shown in every app. Apps find the device by its fixed UID,
// so a rename keeps OBS and other setups working.
struct StreamMixName: View {
    let current: String
    let rename: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Device name", text: $text)
            .textFieldStyle(.roundedBorder).frame(width: 280)
            .focused($focused)
            .onSubmit { rename(text) }
            .onChange(of: focused) { _, isFocused in if !isFocused { rename(text) } }
            .onAppear { text = current }
            .onChange(of: current) { _, name in if !focused { text = name } }
            .help("Rename the virtual device. OBS and other apps keep their setup.")
    }
}
