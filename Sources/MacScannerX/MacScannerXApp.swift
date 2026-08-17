import SwiftUI
import AppKit

@main
struct MacScannerXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = ScanController()

    var body: some Scene {
        WindowGroup("MacScannerX") {
            ContentView(controller: controller)
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Scanner") {
                Button("Preview") { controller.preview() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Scan") { controller.scan() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Save Again") { controller.saveAgain() }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Look for Scanners") { controller.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reset All Settings") { controller.resetSettings() }
            }

            CommandGroup(replacing: .help) {
                Button("MacScannerX Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/HassanNiazi/MacScannerX#readme")!)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.isRequested || SelfTest.isDeviceDumpRequested || SelfTest.isTestScanRequested {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                let code: Int32
                if SelfTest.isTestScanRequested        { code = await SelfTest.testScan() }
                else if SelfTest.isDeviceDumpRequested { code = await SelfTest.dumpDevices() }
                else                                   { code = await SelfTest.run() }
                exit(code)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sizeWindowOnFirstRun()
    }

    /// `.defaultSize` only applies when AppKit has no saved frame, so a window
    /// that once opened at the minimum size stays cramped forever. Size and
    /// centre it once, then leave the user's own resizing alone.
    private func sizeWindowOnFirstRun() {
        let key = "MacScannerXDidSizeWindow"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            window.setContentSize(NSSize(width: 1180, height: 800))
            window.center()
        }
    }
}
