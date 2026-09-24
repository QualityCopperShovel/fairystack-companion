import AppKit
import ServiceManagement
import WorkspaceWindow

let companionVersion = "1.1.0"

final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private let commands = FairyStackCommands()
    private lazy var workspace = WorkspaceWindows(version: companionVersion, pairedOrigin: { [weak self] in self?.commands.pairedOrigin })
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let updateItem = NSMenuItem(title: "Check for updates", action: #selector(checkUpdates), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    private lazy var updater = CompanionUpdater(status: { [weak self] text in
        DispatchQueue.main.async { self?.updateItem.title = text }
    }, installed: { [weak self] in self?.restart() })
    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.image = NSImage(systemSymbolName: "link", accessibilityDescription: "FairyStack Companion")
        let menu = NSMenu()
        let title = NSMenuItem(title: "FairyStack Companion · \(companionVersion)", action: nil, keyEquivalent: "")
        let open = NSMenuItem(title: "Open FairyStack window", action: #selector(WorkspaceWindows.show), keyEquivalent: "")
        let address = NSMenuItem(title: "Change FairyStack address…", action: #selector(WorkspaceWindows.changeAddress), keyEquivalent: "")
        [open, address].forEach { $0.target = workspace }
        let quit = NSMenuItem(title: "Quit FairyStack Companion", action: #selector(quit), keyEquivalent: "q")
        [updateItem, loginItem, quit].forEach { $0.target = self }
        [title, .separator(), open, address, .separator(), commands.menu, commands.activityMenu, .separator(), loginItem, updateItem, .separator(), quit].forEach(menu.addItem)
        status.menu = menu
        NSApp.mainMenu = mainMenu()
        commands.start(); refreshLogin(); updater.start()
        workspace.adopt(CommandLine.arguments); workspace.restore()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspace.show() }
        return true
    }
    // Shown while a FairyStack window makes this a regular app; web views need the Edit actions for ⌘C/⌘V.
    private func mainMenu() -> NSMenu {
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let menu = NSMenu(title: title)
            items.forEach(menu.addItem); item.submenu = menu; return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; return item
        }
        let main = NSMenu()
        main.addItem(submenu("FairyStack", [
            item("About FairyStack Companion", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(), item("Change FairyStack Address…", #selector(WorkspaceWindows.changeAddress), "", target: workspace),
            .separator(), item("Hide FairyStack", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(), item("Quit FairyStack Companion", #selector(quit), "q", target: self)]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")]))
        main.addItem(submenu("View", [
            item("Reload", #selector(WorkspaceWindows.reload), "r", target: workspace),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])]))
        main.addItem(submenu("Window", [
            item("FairyStack Window", #selector(WorkspaceWindows.show), "0", target: workspace),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w")]))
        return main
    }
    func applicationWillTerminate(_ notification: Notification) { commands.stop() }
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
