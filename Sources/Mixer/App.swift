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
    private let router = AudioRouter()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
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
                self.refreshCounters()
                await self.repairIfNeeded()
            }
        }
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
    @StateObject private var store = MixerStore()
    var body: some Scene {
        WindowGroup("Mixoto") {
            MixerView(store: store)
                .frame(minWidth: 800, minHeight: 580)
                .task { await SmokeCheck.runIfRequested(store: store) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reinstall Virtual Device…") { Task { await store.installVirtualDevice() } }.disabled(store.busy)
            }
        }
    }
}

struct MixerView: View {
    @ObservedObject var store: MixerStore
    @State private var showingDebugInfo = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Outputs") {
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
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach($store.settings.channels) { $channel in strip($channel) }
                    Button { store.settings.channels.append(Channel()); store.save() } label: {
                        Image(systemName: "plus").font(.system(size: 28, weight: .light))
                            .frame(width: 120).frame(maxHeight: .infinity)
                            .glass(interactive: true, in: RoundedRectangle(cornerRadius: 16))
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
                    }
                    .padding(20)
                    .frame(minWidth: 220, alignment: .leading)
                    .textSelection(.enabled)
                }
            }.font(.callout)
        }
        .padding(20)
        .onChange(of: store.settings.channels) { _, _ in store.changed() }
        .onChange(of: store.settings.monitorUID) { _, _ in store.changed() }
        .onChange(of: store.settings.streamUID) { _, _ in store.save() }
    }
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
                Button(role: .destructive) { store.settings.channels.removeAll { $0.id == value.id }; store.save() } label: { Image(systemName: "trash") }
                    .glassButton().help("Remove channel")
            }
        }
        .padding(10)
        .frame(width: 170)
        .glass(in: RoundedRectangle(cornerRadius: 16))
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

// Peak level after this mix's gain and mute, -60 to 0 dBFS. Redraws at the
// display refresh rate by reading the audio-side level directly, so the
// rest of the window does not re-render for each frame.
struct LevelMeter: View {
    let level: () -> Float
    var active = true
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { _ in
            let value = active ? level() : 0
            let db = 20 * log10(max(value, 0.000_001))
            let fraction = CGFloat(min(1, max(0, (db + 60) / 60)))
            Canvas { context, size in
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.width / 2)
                context.fill(track, with: .color(.primary.opacity(0.12)))
                let height = size.height * fraction
                guard height > 0 else { return }
                let bar = Path(roundedRect: CGRect(x: 0, y: size.height - height, width: size.width, height: height), cornerRadius: size.width / 2)
                context.fill(bar, with: .color(db > -3 ? .red : db > -12 ? .yellow : .green))
            }
            .accessibilityValue(value > 0.001 ? "\(Int(db)) dB" : "silent")
        }
        .frame(width: 6)
        .accessibilityLabel("Level")
    }
}

// Liquid Glass on macOS 26 and later; a flat fill on macOS 15.
extension View {
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
