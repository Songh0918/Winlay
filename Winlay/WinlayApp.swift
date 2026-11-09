import SwiftUI

@main struct WinlayApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        MenuBarExtra("Winlay", systemImage: "keyboard", isInserted: Binding(get: { model.configuration.effectiveShowMenuBarIcon }, set: { model.setMenuBarIconVisible($0) })) {
            MenuPanel().environmentObject(model)
        }.menuBarExtraStyle(.window)
        Window("Winlay 设置", id: "settings") {
            SettingsView(appDelegate: appDelegate).environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { appDelegate.model = model; model.applyActivationPolicy(); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(.presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var reopenSettings: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasRecovery else { return .terminateNow }
        model.restoreAllMappings()
        return model.hasRecovery ? .terminateCancel : .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenSettings?()
        sender.activate(ignoringOtherApps: true)
        return false
    }
}
