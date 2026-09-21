import AppKit
import ServiceManagement

final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private let commands = FairyStackCommands()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let updateItem = NSMenuItem(title: "Check for updates", action: #selector(checkUpdates), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    private lazy var updater = CompanionUpdater(status: { [weak self] text in
        DispatchQueue.main.async { self?.updateItem.title = text }
    }, installed: { [weak self] in self?.restart() })
    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.image = NSImage(systemSymbolName: "link", accessibilityDescription: "FairyStack Companion")
        let menu = NSMenu()
        let title = NSMenuItem(title: "FairyStack Companion · 1.0.1", action: nil, keyEquivalent: "")
        let open = NSMenuItem(title: "Open FairyStack…", action: #selector(openFairyStack), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit FairyStack Companion", action: #selector(quit), keyEquivalent: "q")
        [updateItem, loginItem, open, quit].forEach { $0.target = self }
        [title, .separator(), commands.menu, commands.activityMenu, open, .separator(), loginItem, updateItem, .separator(), quit].forEach(menu.addItem)
        status.menu = menu
        commands.start(); refreshLogin(); updater.start()
    }
    func applicationWillTerminate(_ notification: Notification) { commands.stop() }
    @objc private func openFairyStack() { NSWorkspace.shared.open(URL(string: "https://fairystack.com/#existing-account")!) }
    @objc private func checkUpdates() { updater.check(announce: true) }
    private func refreshLogin() { loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register(); if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } }
        } catch { let a = NSAlert(); a.messageText = "Login item failed"; a.informativeText = error.localizedDescription; a.runModal() }
        refreshLogin()
    }
    private func restart() {
        commands.stop()
        let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true; config.activates = false
        var finished = false
        let deadline = DispatchWorkItem { if !finished { finished = true; self.updateItem.title = "Update installed · quit and reopen to finish" } }
        DispatchQueue.main.asyncAfter(deadline: .now()+15, execute: deadline)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { application,error in
            DispatchQueue.main.async {
                guard !finished else { application?.terminate(); return }
                finished = true; deadline.cancel()
                if error == nil, let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier { NSApp.terminate(nil) }
                else { self.updateItem.title = "Update installed · quit and reopen to finish" }
            }
        }
    }
    @objc private func quit() { commands.stop(); NSApp.terminate(nil) }
}
let app = NSApplication.shared
let delegate = CompanionDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
