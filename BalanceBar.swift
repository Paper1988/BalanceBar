import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox
import ServiceManagement

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
}

enum AudioCore {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            system, &address, 0, nil, &size
        ) == noErr else {
            return []
        }

        var ids = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )

        guard AudioObjectGetPropertyData(
            system, &address, 0, nil, &size, &ids
        ) == noErr else {
            return []
        }

        return ids
    }

    static func name(of id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &name
        )

        guard status == noErr, let name else {
            return ""
        }

        return name.takeRetainedValue() as String
    }

    static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            id, &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )

        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, raw
        ) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )

        return list.reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    static func balanceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func supportsBalance(_ id: AudioObjectID) -> Bool {
        var address = balanceAddress()
        return AudioObjectHasProperty(id, &address)
    }

    static func balance(of id: AudioObjectID) -> Double? {
        var address = balanceAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &size, &value
        ) == noErr else {
            return nil
        }

        return min(1.0, max(0.0, Double(value)))
    }

    @discardableResult
    static func setBalance(_ id: AudioObjectID, _ value: Double) -> Bool {
        var address = balanceAddress()
        var v = Float32(min(1.0, max(0.0, value)))

        return AudioObjectSetPropertyData(
            id,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &v
        ) == noErr
    }

    static func defaultOutputID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        guard AudioObjectGetPropertyData(
            system, &address, 0, nil, &size, &id
        ) == noErr, id != 0 else {
            return nil
        }

        return id
    }

    static func outputDevices() -> [OutputDevice] {
        allDeviceIDs()
            .filter {
                outputChannelCount($0) > 0 && supportsBalance($0)
            }
            .map {
                OutputDevice(id: $0, name: name(of: $0))
            }
    }
}

@MainActor
final class BalanceModel: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var currentName = ""
    @Published var targets: [String: Double]
    @Published var launchAtLogin: Bool

    // 即使目標值沒有改變，也能通知 SwiftUI 重新讀取硬體值。
    @Published private var balanceRevision = 0

    private let defaultsKey = "targets"

    private var retryTasks: [Task<Void, Never>] = []

    private var balanceListeners:
        [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    private var systemListenersInstalled = false

    init() {
        let defaults = UserDefaults.standard

        let stored = defaults.dictionary(
            forKey: defaultsKey
        ) as? [String: Double]

        let storedV2 = defaults.dictionary(
            forKey: "targetsV2"
        ) as? [String: Double]

        let initialTargets: [String: Double]

        if let stored {
            initialTargets = stored.mapValues {
                min(1.0, max(0.0, $0))
            }
        } else if let storedV2 {
            // 將舊版 -1...1 數值轉回 CoreAudio 的 0...1。
            initialTargets = storedV2.mapValues {
                min(1.0, max(0.0, ($0 + 1.0) / 2.0))
            }
        } else {
            initialTargets = ["Paper-airpods": 0.7]
        }

        targets = initialTargets
        launchAtLogin = SMAppService.mainApp.status == .enabled

        defaults.set(initialTargets, forKey: defaultsKey)
        defaults.removeObject(forKey: "targetsV2")

        installSystemListeners()
        refresh()
        applyWithRetries()
    }

    deinit {
        retryTasks.forEach { $0.cancel() }

        for (id, listener) in balanceListeners {
            var address = AudioCore.balanceAddress()

            AudioObjectRemovePropertyListenerBlock(
                id, &address, .main, listener
            )
        }
    }

    // MARK: - Balance

    func value(for device: OutputDevice) -> Double {
        // 讀取此 Published 屬性，確保硬體值變更時 UI 會重新計算。
        _ = balanceRevision

        if let target = targets[device.name] {
            return target
        }

        return AudioCore.balance(of: device.id) ?? 0.5
    }

    func set(_ device: OutputDevice, to value: Double) {
        let clamped = min(1.0, max(0.0, value))
        let rounded = (clamped * 100).rounded() / 100

        targets[device.name] = rounded
        UserDefaults.standard.set(targets, forKey: defaultsKey)

        let success = AudioCore.setBalance(device.id, rounded)

        if !success {
            print("Failed to set balance for:", device.name)
        }

        balanceRevision += 1
    }

    func adjust(_ device: OutputDevice, to value: Double) {
        set(device, to: value)
    }

    func clear(_ device: OutputDevice) {
        targets[device.name] = nil
        UserDefaults.standard.set(targets, forKey: defaultsKey)

        // 清除自動套用設定，不會重設目前的硬體平衡。
        balanceRevision += 1
    }

    private func apply() {
        guard let id = AudioCore.defaultOutputID() else {
            return
        }

        let name = AudioCore.name(of: id)

        guard let value = targets[name] else {
            return
        }

        AudioCore.setBalance(id, value)
    }

    // MARK: - Listeners

    private func installSystemListeners() {
        guard !systemListenersInstalled else {
            return
        }

        systemListenersInstalled = true

        var output = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let outputStatus = AudioObjectAddPropertyListenerBlock(
            AudioCore.system,
            &output,
            .main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.outputChanged()
            }
        }

        if outputStatus != noErr {
            print("Default output listener failed:", outputStatus)
        }

        var list = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listStatus = AudioObjectAddPropertyListenerBlock(
            AudioCore.system,
            &list,
            .main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        if listStatus != noErr {
            print("Device list listener failed:", listStatus)
        }
    }

    private func syncBalanceListeners() {
        let activeIDs = Set(devices.map(\.id))

        // 移除已不在輸出裝置清單內的 listener。
        for id in Array(balanceListeners.keys)
        where !activeIDs.contains(id) {
            guard let listener = balanceListeners.removeValue(
                forKey: id
            ) else {
                continue
            }

            var address = AudioCore.balanceAddress()

            AudioObjectRemovePropertyListenerBlock(
                id, &address, .main, listener
            )
        }

        // 每個支援平衡的輸出裝置都監聽自己的平衡屬性。
        for device in devices
        where balanceListeners[device.id] == nil {
            let id = device.id

            let listener: AudioObjectPropertyListenerBlock = {
                [weak self] _, _ in

                Task { @MainActor in
                    self?.balanceChanged(for: id)
                }
            }

            var address = AudioCore.balanceAddress()

            let status = AudioObjectAddPropertyListenerBlock(
                id,
                &address,
                .main,
                listener
            )

            if status == noErr {
                balanceListeners[id] = listener
            } else {
                print("Balance listener failed:", id, status)
            }
        }
    }

    private func balanceChanged(for id: AudioObjectID) {
        guard let actual = AudioCore.balance(of: id) else {
            return
        }

        let name = AudioCore.name(of: id)

        // 若這個裝置原本有自動套用設定，
        // 將系統目前的值同步保存，避免之後套回舊值。
        if let saved = targets[name],
           abs(saved - actual) > 0.0001 {
            targets[name] = actual
            UserDefaults.standard.set(targets, forKey: defaultsKey)
        }

        if AudioCore.defaultOutputID() == id {
            currentName = name
        }

        // 即使沒有 targets，也會讓 UI 重新讀取實際硬體值。
        balanceRevision += 1
    }

    // MARK: - Refresh

    func refresh() {
        devices = AudioCore.outputDevices()
        syncBalanceListeners()

        if let id = AudioCore.defaultOutputID() {
            currentName = AudioCore.name(of: id)
        }

        balanceRevision += 1
    }

    private func outputChanged() {
        refresh()
        applyWithRetries()
    }

    private func applyWithRetries() {
        retryTasks.forEach { $0.cancel() }

        apply()

        retryTasks = [1.0, 2.5, 5.0].map { delay in
            Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }

                guard !Task.isCancelled else {
                    return
                }

                self?.apply()
            }
        }
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login failed:", error)
        }

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}



struct DetentSlider: View {
    @Binding var value: Double
    let label: String
    let onDragEnded: ((Double) -> Void)?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private let thumbSize: CGFloat = 20
    private let trackHeight: CGFloat = 6
    private let height: CGFloat = 30

    init(
        value: Binding<Double>,
        label: String,
        onDragEnded: ((Double) -> Void)? = nil
    ) {
        self._value = value
        self.label = label
        self.onDragEnded = onDragEnded
    }

    private func commit(_ newValue: Double) {
        let clamped = min(1.0, max(0.0, newValue))
        guard abs(clamped - value) > 0.0001 else { return }

        value = clamped

        let scaled = clamped * 10
        if abs(scaled - scaled.rounded()) < 0.0001 {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
    }

    private func nudge(_ delta: Double) {
        let base = (value * 10).rounded() / 10
        let next = min(1.0, max(0.0, base + delta))
        commit((next * 100).rounded() / 100)
        onDragEnded?(value)
    }

    private func sliderValue(
        at x: CGFloat,
        width: CGFloat,
        fine: Bool
    ) -> Double {
        let travel = max(1, width - thumbSize)
        let raw = min(
            1.0,
            max(0.0, Double((x - thumbSize / 2) / travel))
        )

        return fine
            ? (raw * 100).rounded() / 100
            : (raw * 10).rounded() / 10
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(0, geo.size.width - thumbSize)
            let midY = geo.size.height / 2
            let centerX = thumbSize / 2 + travel * 0.5
            let valueX = thumbSize / 2 + travel * CGFloat(value)

            ZStack {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: travel, height: trackHeight)
                    .position(x: geo.size.width / 2, y: midY)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: max(abs(valueX - centerX), 0.5),
                        height: trackHeight
                    )
                    .position(
                        x: (centerX + valueX) / 2,
                        y: midY
                    )

                ForEach(0..<11, id: \.self) { i in
                    Capsule()
                        .fill(
                            i == 5
                                ? Color.secondary
                                : Color.secondary.opacity(0.45)
                        )
                        .frame(
                            width: 2,
                            height: i == 5 ? 16 : 10
                        )
                        .position(
                            x: thumbSize / 2
                                + travel * CGFloat(i) / 10,
                            y: midY
                        )
                }

                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay {
                        Circle().strokeBorder(
                            Color.accentColor,
                            lineWidth: 2
                        )
                    }
                    .shadow(
                        color: .black.opacity(0.25),
                        radius: 2,
                        y: 1
                    )
                    .position(x: valueX, y: midY)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: value
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { drag in
                        guard travel > 0 else { return }

                        let next = sliderValue(
                            at: drag.location.x,
                            width: geo.size.width,
                            fine: NSEvent.modifierFlags.contains(.option)
                        )

                        commit(next)
                    }
                    .onEnded { _ in
                        onDragEnded?(value)
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { tap in
                        guard travel > 0 else { return }

                        let next = sliderValue(
                            at: tap.location.x,
                            width: geo.size.width,
                            fine: NSEvent.modifierFlags.contains(.option)
                        )

                        // 點擊只調整硬體值，不觸發儲存回呼。
                        commit(next)
                    }
            )
        }
        .frame(height: height)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down:
                nudge(-0.1)
            case .right, .up:
                nudge(0.1)
            default:
                break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                nudge(0.1)
            case .decrement:
                nudge(-0.1)
            @unknown default:
                break
            }
        }
    }
}


struct DeviceCard: View {
    @ObservedObject var model: BalanceModel
    let device: OutputDevice

    private var isCurrent: Bool {
        model.currentName == device.name
    }

    private var value: Double {
        model.value(for: device)
    }

    private var icon: String {
        let lower = device.name.lowercased()

        if lower.contains("airpods") {
            return "airpods"
        }

        if lower.contains("headphone") || lower.contains("buds") {
            return "headphones"
        }

        return "speaker.wave.2.fill"
    }

    private var direction: String {
        if abs(value - 0.5) < 0.005 {
            return "置中"
        }

        return value < 0.5 ? "偏左" : "偏右"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(
                        isCurrent ? Color.accentColor : Color.secondary
                    )

                Text(device.name)
                    .font(
                        .system(
                            .body,
                            design: .rounded,
                            weight: .semibold
                        )
                    )
                    .lineLimit(1)

                if isCurrent {
                    Text("使用中")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.18))
                        }
                        .foregroundStyle(Color.accentColor)
                }

                Spacer(minLength: 4)

                Text(String(format: "%.2f", value))
                    .font(
                        .system(
                            .title3,
                            design: .rounded,
                            weight: .bold
                        )
                    )
                    .monospacedDigit()
            }

            DetentSlider(
                value: Binding(
                    get: { model.value(for: device) },
                    set: { newValue in
                        AudioCore.setBalance(device.id, newValue)
                    }
                ),
                label: "\(device.name) 左右平衡",
                onDragEnded: { newValue in
                    model.set(device, to: newValue)
                }
            )

            HStack {
                Text("L")
                Spacer()
                Text(direction)
                Spacer()
                Text("R")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            if model.targets[device.name] != nil {
                HStack {
                    Label(
                        "連線時自動套用",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)

                    Spacer()

                    Button("清除") {
                        model.clear(device)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            } else {
                Text("拖動滑桿後會記住這個值")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
            .fill(.quaternary.opacity(0.5))
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: BalanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")

                Text("音訊平衡")
                    .font(
                        .system(
                            .headline,
                            design: .rounded,
                            weight: .bold
                        )
                    )

                Spacer()

                Text("Option 微調")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.devices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.slash")
                        .font(.title2)

                    Text("沒有支援平衡的輸出裝置")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            ForEach(model.devices) { device in
                DeviceCard(model: model, device: device)
            }

            HStack {
                Toggle(
                    "開機自動啟動",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button("結束") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 310)
    }
}

@main
struct BalanceBarApp: App {
    @StateObject private var model = BalanceModel()

    var body: some Scene {
	    MenuBarExtra {
	        ContentView(model: model)
	    } label: {
		    Group {
		        if let url = Bundle.main.url(
		            forResource: "BalanceBarIcon",
		            withExtension: "png"
		        ), let nsImage = NSImage(contentsOf: url) {
		            Image(nsImage: nsImage)
		                .renderingMode(.template)
		                .resizable()
		                .scaledToFit()
		                .frame(width: 18, height: 18)
		        } else {
		            Image(systemName: "slider.horizontal.3")
		        }
		    }
		}
        .menuBarExtraStyle(.window)
    }
}
