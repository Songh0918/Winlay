import SwiftUI
import AppKit
import Metal
import Sparkle
import UniformTypeIdentifiers

private enum GlassGraphics {
    static let hasMetalDevice = MTLCreateSystemDefaultDevice() != nil
}

private struct ScrollProfileEditor: View {
    @Binding var profile: ScrollProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                Toggle("垂直滚动反向", isOn: $profile.reverseVertical)
                Toggle("水平滚动反向", isOn: $profile.reverseHorizontal)
            }
            HStack(spacing: 24) {
                Toggle("垂直平滑滚动", isOn: $profile.smoothVertical)
                Toggle("水平平滑滚动", isOn: $profile.smoothHorizontal)
            }
            HStack {
                Text("滚动速度").frame(width: 80, alignment: .leading)
                Slider(value: $profile.speed, in: 0.25...4, step: 0.05)
                Text("\(profile.effectiveSpeed, specifier: "%.2f")×").monospacedDigit().frame(width: 50)
            }
            HStack {
                Text("平滑时长").frame(width: 80, alignment: .leading)
                Slider(value: $profile.duration, in: 0.08...0.6, step: 0.01)
                Text("\(profile.effectiveDuration, specifier: "%.2f") 秒").monospacedDigit().frame(width: 50)
            }.disabled(!profile.smoothVertical && !profile.smoothHorizontal)
        }
    }
}

private struct MouseScrollView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: MouseScrollService
    @State private var selectionError: String?

    private var settings: MouseScrollSettings { model.configuration.mouseScroll ?? MouseScrollSettings() }
    private func edit(_ body: (inout MouseScrollSettings) -> Void, prompt: Bool = false) {
        var next = settings; body(&next); model.setMouseScroll(next, promptForPermission: prompt)
    }
    private var globalProfile: Binding<ScrollProfile> {
        Binding(get: { settings.global }, set: { value in edit { $0.global = value } })
    }
    private func ruleProfile(_ id: String) -> Binding<ScrollProfile> {
        Binding(get: { settings.applications.first(where: { $0.id == id })?.profile ?? ScrollProfile() }, set: { value in
            edit { settings in if let index = settings.applications.firstIndex(where: { $0.id == id }) { settings.applications[index].profile = value } }
        })
    }
    private func bypass(_ id: String) -> Binding<Bool> {
        Binding(get: { settings.applications.first(where: { $0.id == id })?.bypass ?? true }, set: { value in
            edit { settings in if let index = settings.applications.firstIndex(where: { $0.id == id }) { settings.applications[index].bypass = value } }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("启用鼠标滚轮增强", isOn: Binding(get: { settings.enabled }, set: { value in edit({ $0.enabled = value }, prompt: value) }))
            LabeledContent("状态", value: service.status)
            if settings.enabled && service.status != "已开启" {
                HStack {
                    Button("重新检查权限") { model.setMouseScroll(settings, promptForPermission: true) }
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }
                }
                Text("需要在系统设置中允许 Winlay 使用辅助功能，才能调整滚轮事件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("只调整符合条件的离散滚轮事件，连续滚动和触控板手势会放行。系统不提供可靠的事件设备身份，部分高精度鼠标或非标准设备可能无法正确区分。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("全局滚动设置").font(.headline)
            ScrollProfileEditor(profile: globalProfile).disabled(!settings.enabled)
            Divider()
            HStack {
                Text("应用例外").font(.headline)
                Spacer()
                Button("添加应用…") { chooseApplication() }
            }
            Text("根据前台应用应用例外；可跳过处理或为应用单独设置滚动方式。")
                .font(.caption).foregroundStyle(.secondary)
            if let selectionError { Text(selectionError).foregroundStyle(.red) }
            if settings.applications.isEmpty { Text("尚未添加应用例外。 ").foregroundStyle(.secondary) }
            ForEach(settings.applications) { rule in
                DisclosureGroup(rule.name) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("在此应用中跳过滚轮处理", isOn: bypass(rule.id))
                        if !rule.bypass { ScrollProfileEditor(profile: ruleProfile(rule.id)) }
                        Button("移除此应用", role: .destructive) { edit { $0.applications.removeAll { $0.id == rule.id } } }
                    }.padding(.vertical, 8)
                }
            }
            Text("启用时只处理滚轮事件，不记录或上传输入内容。与其他滚轮增强工具同时启用可能互相影响。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
                selectionError = "无法识别该应用，请选择有效的应用程序。"; return
            }
            guard !settings.applications.contains(where: { $0.id == id }) else { selectionError = "该应用已添加。"; return }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            edit { $0.applications.append(ScrollApplicationRule(bundleIdentifier: id, name: name, profile: $0.global)) }
            selectionError = nil
        }
    }
}

private struct GlassActions: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), SystemAppearance.usesGlass(
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            hasMetalDevice: GlassGraphics.hasMetalDevice, reduceTransparency: reduceTransparency) {
            content.buttonStyle(.bordered).padding(6)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            content
        }
    }
}

final class UpdateAvailability: ObservableObject {
    @Published var canCheck = false
    init(updater: SPUUpdater) { updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck) }
}

struct CheckForUpdatesButton: View {
    private let updater: SPUUpdater
    @StateObject private var availability: UpdateAvailability
    init(updater: SPUUpdater) {
        self.updater = updater
        _availability = StateObject(wrappedValue: UpdateAvailability(updater: updater))
    }
    var body: some View {
        Button("检查更新…") { updater.checkForUpdates() }.disabled(!availability.canCheck)
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingWindows = false
    let appDelegate: AppDelegate
    private var statusColor: Color {
        if model.errorMessage != nil { return .red }
        if model.mappingActive { return .green }
        if model.selectedHasRecovery { return .orange }
        return .secondary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Winlay").font(.headline)
                Spacer()
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(model.selectedDevice?.name ?? "未选择键盘", systemImage: "keyboard")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack {
                    Text("当前模式：\(model.mappingActive ? "自定义映射" : model.selectedHasRecovery ? "恢复待处理" : "完全原样")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.activeDevices.isEmpty {
                        Text("生效 \(model.activeDevices.count) 台")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.mappingActive || model.selectedHasRecovery {
                    Button { model.restoreMapping() } label: {
                        Text("暂停并恢复当前键盘").frame(maxWidth: .infinity)
                    }.controlSize(.regular)
                } else {
                    Button { confirmingWindows = true } label: {
                        Text("启用 Mac 键位布局").frame(maxWidth: .infinity)
                    }.controlSize(.regular).disabled(!model.canApply)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.mappingReason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.offlineRecoveryCount > 0 {
                    Spacer(minLength: 4)
                    Button("清理旧记录") { model.clearOfflineRecoveryJournals() }
                        .controlSize(.small)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("打开设置…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                CheckForUpdatesButton(updater: appDelegate.updaterController.updater)
                Spacer()
                Button("退出 Winlay") { NSApp.terminate(nil) }
            }
        }.padding(16).frame(width: 340, alignment: .leading)
        .alert("启用 Mac 键位布局？", isPresented: $confirmingWindows) {
            Button("取消", role: .cancel) {}
            Button("启用") { model.applyWindows() }
        } message: { Text("将应用按键页面中启用的映射。可随时暂停并恢复。") }
    }
}

enum SectionID: String, CaseIterable, Identifiable {
    case overview = "概览", keys = "按键", mouse = "鼠标", shortcuts = "快捷键", devices = "设备", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .overview: return "house"; case .keys: return "keyboard"; case .mouse: return "computermouse"; case .shortcuts: return "command"; case .devices: return "cable.connector"; case .settings: return "gearshape" }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate
    @State private var deviceToConfirm: KeyboardDevice?
    @State private var sourceKey: UInt64 = 4
    @State private var destinationKey: UInt64 = 5
    @State private var confirmingWindows = false
    var body: some View {
        NavigationSplitView {
            List(SectionID.allCases, selection: $model.selection) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                .navigationSplitViewColumnWidth(min: 140, ideal: 170)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.selection?.rawValue ?? "概览").font(.largeTitle.bold())
                    if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                    switch model.selection ?? .overview {
                    case .overview: overview
                    case .keys: keys
                    case .mouse: MouseScrollView(service: model.mouseScrollService)
                    case .shortcuts: shortcuts
                    case .devices: deviceList
                    case .settings: settings
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { let open = openWindow; appDelegate.reopenSettings = { open(id: "settings") } }
        .sheet(isPresented: $model.showingOnboarding) { onboarding }
        .confirmationDialog("确认选择键盘", isPresented: Binding(get: { deviceToConfirm != nil }, set: { if !$0 { deviceToConfirm = nil } }), titleVisibility: .visible, presenting: deviceToConfirm) { device in
            Button("确认选择 \(device.name)") { model.select(device); deviceToConfirm = nil }
        } message: { _ in
            Text("请确认设备身份；映射将应用到该键盘的匹配接口。内置键盘的修改会影响本机操作，请确保有其他输入设备可用。")
        }
        .alert("启用 Mac 键位布局？", isPresented: $confirmingWindows) {
            Button("取消", role: .cancel) {}
            Button("启用") { model.applyWindows() }
        } message: { Text("将应用按键页面中启用的映射。可随时暂停并恢复。") }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("状态", value: model.status)
            LabeledContent("当前键盘", value: model.selectedDevice?.name ?? "未选择")
            LabeledContent("当前模式", value: model.mappingActive ? "自定义映射" : model.selectedHasRecovery ? "恢复待处理" : "完全原样")
            LabeledContent("正在生效的键盘", value: "\(model.activeDevices.count) 台")
            Divider()
            Label(model.mappingActive ? "已写入当前键盘映射" : model.selectedHasRecovery ? "当前键盘恢复待处理" : "当前键盘映射已暂停", systemImage: model.mappingActive ? "checkmark.circle" : "pause.circle")
            Text(model.mappingReason).foregroundStyle(.secondary)
            Text("Winlay 不会将全局映射作为设备级映射的替代方案。").foregroundStyle(.secondary)
            HStack {
                if model.mappingActive || model.selectedHasRecovery { Button("暂停并恢复当前键盘") { model.restoreMapping() } }
                else { Button("启用 Mac 键位布局") { confirmingWindows = true }.disabled(!model.canApply) }
                if model.mappingActive { Button("检查当前映射") { model.verifyCurrentMapping() } }
                if model.offlineRecoveryCount > 0 { Button("清理旧设备记录") { model.clearOfflineRecoveryJournals() } }
                Button("重新检测") { model.refresh() }
            }.modifier(GlassActions())
        }
    }
    private var keys: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedDevice?.name ?? "请先选择键盘").font(.headline)
            Text("每把键盘的规则单独保存，可以同时启用多把键盘。")
            HStack { Text("Windows 输入").frame(width: 180, alignment: .leading); Text("Mac 输出").frame(width: 180, alignment: .leading); Spacer() }.foregroundStyle(.secondary)
            ForEach(model.currentRules) { rule in
                HStack {
                    Text(KeyboardKey.name(rule.source, mac: false)).frame(width: 180, alignment: .leading)
                    Text(KeyboardKey.name(rule.destination, mac: true)).frame(width: 180, alignment: .leading)
                    Toggle("启用", isOn: Binding(get: { model.currentRules.first(where: { $0.source == rule.source })?.enabled ?? false }, set: { model.setRuleEnabled(rule.source, enabled: $0) })).labelsHidden()
                    Button("删除") { model.removeRule(rule.source) }
                }.disabled(model.selectedHasRecovery && !model.mappingActive)
            }
            Divider()
            HStack {
                Picker("Windows 输入", selection: $sourceKey) { ForEach(KeyboardKey.all) { key in Text(key.windows).tag(key.id) } }.labelsHidden().frame(width: 180)
                Picker("Mac 输出", selection: $destinationKey) { ForEach(KeyboardKey.all) { key in Text(key.mac).tag(key.id) } }.labelsHidden().frame(width: 180)
                Button("添加映射") { model.addRule(source: sourceKey, destination: destinationKey) }
            }.disabled(model.selectedDevice == nil || (model.selectedHasRecovery && !model.mappingActive))
            Text("同一个输入按键只能对应一条规则。要更改输出，请先删除旧规则再添加。更改生效时会先恢复原映射，再应用所选规则。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.mappingReason).foregroundStyle(.secondary)
            if model.mappingActive || model.selectedHasRecovery { Button("暂停并恢复当前键盘") { model.restoreMapping() } }
            else { Button("启用 Mac 键位布局") { confirmingWindows = true }.disabled(!model.canApply) }
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常用快捷键").font(.headline)
            Text("启用左侧 Alt → Command 后，可使用 Alt+C 复制、Alt+V 粘贴、Alt+X 剪切、Alt+Z 撤销、Alt+A 全选、Alt+S 保存。")
            Text("这些组合使用的是系统 HID 驱动层单键映射（优先级高于浏览器和普通应用），不是独立的组合键规则。单条快捷键开关、自定义组合和应用例外尚未实现。")
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("快捷键环境诊断").font(.headline)
                Spacer()
                Button("检查快捷键状态") { model.inspectShortcutEnvironment() }
            }
            Text("如果在部分浏览器输入框中无法触发 Cmd+空格 或其他快捷键，通常不是映射优先级不足，而是中文输入法组词态、密码框安全输入、网页脚本或浏览器扩展拦截了按键，或系统快捷键分配冲突。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.shortcutDiagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.shortcutDiagnostics.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)").font(.caption).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.devices.isEmpty { Text("未发现键盘设备").foregroundStyle(.secondary) }
            ForEach(deviceGroups, id: \.first!.id) { group in
                let device = group[0]
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(device.name).font(.headline)
                        if let id = device.matchingIdentity, model.activeDevices.contains(id) { Text("映射已启用").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.selectedDevice?.id == device.id { Text("已选择").foregroundStyle(.secondary) }
                        else if let identity = device.matchingIdentity, identity.isCompatibleGroup(in: model.devices) { Button("选择") { if device.builtIn == true || (device.builtIn == nil && device.transport.lowercased() == "usb") { deviceToConfirm = device } else { model.select(device) } } }
                    }
                    Text("\(device.transport) · \(device.builtIn == true ? "内置" : device.builtIn == false ? "外接" : device.transport.localizedCaseInsensitiveContains("bluetooth") ? "蓝牙外接" : "系统未提供内置状态")")
                    Text("Vendor ID: \(hex(device.vendorID))  Product ID: \(hex(device.productID))  Location ID: \(hex(device.locationID))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if group.count > 1 {
                        Text("系统报告了 \(group.count) 个匹配的 HID 接口；启用前会检查各接口的映射。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Divider()
            }
            Text("内置键盘及内置状态未知的 USB 设备需要确认身份。设备必须提供完整、可区分的标识；鼠标等设备的键盘接口也可能出现在此处。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var deviceGroups: [[KeyboardDevice]] {
        model.devices.reduce(into: []) { groups, device in
            if let vendor = device.vendorID, vendor > 0, let product = device.productID, product > 0,
               let location = device.locationID, location > 0,
               let index = groups.firstIndex(where: { group in
                   guard let first = group.first else { return false }
                   return first.vendorID == vendor && first.productID == product && first.locationID == location
                       && first.name == device.name && first.transport == device.transport && first.builtIn == device.builtIn
               }) {
                groups[index].append(device)
            } else {
                groups.append([device])
            }
        }
    }
    private func hex(_ value: Int?) -> String { value.map { String(format: "0x%04X", $0) } ?? "不可用" }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("通用").font(.headline)
            Toggle("在程序坞显示图标", isOn: Binding(get: { model.configuration.effectiveShowDockIcon }, set: { model.setDockIconVisible($0) }))
            Toggle("在菜单栏显示图标", isOn: Binding(get: { model.configuration.effectiveShowMenuBarIcon }, set: { model.setMenuBarIconVisible($0) }))
            Text("请至少保留一个图标，以便随时打开设置。登录时启动需要在下方开启；启用过的键盘在原连接位置可用时会尝试重新应用映射。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("设备检测").font(.headline)
            Stepper(value: Binding(get: { model.configuration.effectiveDeviceRefreshInterval }, set: { model.setDeviceRefreshInterval($0) }), in: 0.5...30, step: 0.5) {
                Text("设备列表刷新间隔：\(model.configuration.effectiveDeviceRefreshInterval, specifier: "%.1f") 秒")
            }
            HStack {
                Text("推荐 2 秒。仅影响设备连接状态刷新，不会改变按键或快捷键响应速度。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复推荐值") { model.setDeviceRefreshInterval(2) }
            }
            Divider()
            LabeledContent("登录时启动", value: model.loginStatus)
            HStack {
                Button("开启") { model.setLogin(enabled: true) }.disabled(model.loginStatus == "已开启")
                Button("关闭") { model.setLogin(enabled: false) }.disabled(model.loginStatus == "未开启")
                Button("重新检测") { model.updateLoginStatus() }
            }.modifier(GlassActions())
            Divider()
            Text("软件更新").font(.headline)
            CheckForUpdatesButton(updater: appDelegate.updaterController.updater)
            Text("自动检查更新；安装前需要确认并重启 Winlay。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("权限").font(.headline)
            Text("单键映射通过系统 HID 服务设置；当前版本不监听或记录按键内容。")
                .foregroundStyle(.secondary)
            Text("界面跟随系统外观。配置保存在本机，不采集或上传输入内容。")
                .foregroundStyle(.secondary)
            Button("退出 Winlay") { NSApp.terminate(nil) }
        }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 Winlay 键桥").font(.title.bold())
            Text("Winlay 从菜单栏查看键盘状态。当前版本只读取设备信息，不监听或记录输入内容。")
            Text("启用前请选择键盘。映射按设备设置；请验证实际按键和其他键盘行为。")
            Text("Mac 键位布局保留 Ctrl 的 Control 功能。")
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("知道了") { model.completeOnboarding() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 480)
    }
}
