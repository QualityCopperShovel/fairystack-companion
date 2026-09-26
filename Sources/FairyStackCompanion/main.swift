import AppKit
import ServiceManagement
import WorkspaceWindow

let appVersion = "1.11.0"
// Builds before 1.2 used legacyBundleName. Their updaters pin the bundle ID and executable name,
// so only the folder name changes; a legacy install moves itself once on first launch.
let appBundleName = "FairyStack.app"
let legacyBundleName = "FairyStack Companion.app"
let loginItemArgument = "--fairystack-login-item"
/// Waits for the old process to exit (killing it after 10 s), then opens the new build, retrying twice.
/// $1 old pid, $2 open executable, $3 bundle, then app arguments. Detached, so it outlives this process.
let relaunchScript = """
pid=$1; opener=$2; bundle=$3; shift 3
deadline=$(($(date +%s) + 10))
while kill -0 "$pid" 2>/dev/null; do [ "$(date +%s)" -ge "$deadline" ] && { kill -9 "$pid" 2>/dev/null; sleep 0.5; break; }; sleep 0.1; done
for attempt in 1 2 3; do "$opener" -n -g "$bundle" --args "$@" && exit 0; sleep 2; done
exit 1
"""

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let commands = FairyStackCommands()
    private lazy var workspace: WorkspaceWindows = {
        let windows = WorkspaceWindows(version: appVersion, pairedOrigin: { [weak self] in self?.commands.pairedOrigin })
        windows.connectLocal = { [weak self] origin, token, window, completion in
            guard let self else { completion("FairyStack closed."); return }
            self.commands.connectFromWindow(origin: origin, token: token, window: window, completion: completion)
        }
        windows.openWebsite = { [weak self] url in self?.browser.open(url) }
        return windows
    }()
    private lazy var browser: BrowserWindows = {
        let windows = BrowserWindows(version: appVersion)
        windows.sharePage = { [weak self] text in self?.workspace.shareBrowserPage(text) }
        return windows
    }()
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let updateItem = NSMenuItem(title: "Check for updates", action: #selector(checkUpdates), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    private lazy var updater = AppUpdater(status: { [weak self] text in
        DispatchQueue.main.async { self?.updateItem.title = text }
    }, installed: { [weak self] in self?.scheduleUpdateActivation() })
    private var updateActivationTimer: Timer?
    private var checkingUpdateActivation = false
    private var openedByURL = false
    func application(_ application: NSApplication, open urls: [URL]) {
        openedByURL = true
        urls.forEach(workspace.handleOpenURL)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let installed = offerMoveToApplications() {
            relaunch(installed, arguments: Array(CommandLine.arguments.dropFirst())) { [weak self] in
                self?.finishLaunching(updates: false)
                self?.updateItem.title = "Open FairyStack from Applications to finish"
            }
            return
        }
        guard let renamed = adoptBundleName() else { finishLaunching(updates: true); return }
        var arguments = Array(CommandLine.arguments.dropFirst())
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister(); arguments.append(loginItemArgument) }
        relaunch(renamed, arguments: arguments) { [weak self] in
            self?.finishLaunching(updates: false)
            self?.updateItem.title = "Moved to FairyStack.app · quit and reopen to finish"
        }
    }
    /// An app opened straight from its disk image (or translocated by Gatekeeper) cannot update itself.
    private func offerMoveToApplications() -> URL? {
        let current = Bundle.main.bundleURL
        guard current.path.hasPrefix("/Volumes/") || current.path.contains("/AppTranslocation/") else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        let offer = NSAlert(); offer.messageText = "Move FairyStack to Applications?"
        offer.informativeText = "FairyStack is running from the download, so it can’t keep itself up to date."
        offer.addButton(withTitle: "Move to Applications"); offer.addButton(withTitle: "Not Now")
        guard offer.runModal() == .alertFirstButtonReturn else { return nil }
        let manager = FileManager.default
        for folder in [URL(fileURLWithPath: "/Applications", isDirectory: true), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)] {
            // An existing install (either name) updates itself; open it rather than duplicating it.
            for name in [appBundleName, legacyBundleName] where manager.fileExists(atPath: folder.appendingPathComponent(name).path) { return folder.appendingPathComponent(name, isDirectory: true) }
        }
        for folder in [URL(fileURLWithPath: "/Applications", isDirectory: true), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)] {
            let target = folder.appendingPathComponent(appBundleName, isDirectory: true)
            do { try manager.createDirectory(at: folder, withIntermediateDirectories: true); try manager.copyItem(at: current, to: target); return target }
            catch { NSLog("FairyStack could not copy itself to %@: %@", folder.path, error.localizedDescription) }
        }
        let failed = NSAlert(); failed.messageText = "FairyStack could not be moved"
        failed.informativeText = "Drag FairyStack into your Applications folder, then open it from there."; failed.runModal()
        return nil
    }
    /// Moves a legacyBundleName install to appBundleName; returns the new bundle to relaunch.
    private func adoptBundleName() -> URL? {
        let current = Bundle.main.bundleURL
        guard current.lastPathComponent == legacyBundleName else { return nil }
        let renamed = current.deletingLastPathComponent().appendingPathComponent(appBundleName, isDirectory: true)
        // The installer already placed FairyStack.app beside this copy; hand over to it.
        if FileManager.default.fileExists(atPath: renamed.path) { return renamed }
        do { try FileManager.default.moveItem(at: current, to: renamed); return renamed }
        catch { NSLog("FairyStack could not rename %@: %@", current.path, error.localizedDescription); return nil }
    }
    private func finishLaunching(updates: Bool) {
        status.button?.image = FairyIcon.menuBar()
        let menu = NSMenu()
        let title = NSMenuItem(title: "FairyStack · \(appVersion)", action: nil, keyEquivalent: "")
        let open = NSMenuItem(title: "Open FairyStack window", action: #selector(WorkspaceWindows.show), keyEquivalent: "")
        let browse = NSMenuItem(title: "Open Browser window", action: #selector(BrowserWindows.show), keyEquivalent: ""); browse.target = browser
        let address = NSMenuItem(title: "Add stack by address…", action: #selector(WorkspaceWindows.changeAddress), keyEquivalent: "")
        [open, address].forEach { $0.target = workspace }
        let quit = NSMenuItem(title: "Quit FairyStack", action: #selector(quit), keyEquivalent: "q")
        [updateItem, loginItem, quit].forEach { $0.target = self }
        [title, .separator(), open, browse, address, .separator(), commands.menu, commands.activityMenu, .separator(), loginItem, updateItem, .separator(), quit].forEach(menu.addItem)
        workspace.installStackMenu(in: menu, before: open)
        status.menu = menu
        NSApp.mainMenu = mainMenu()
        if CommandLine.arguments.contains(loginItemArgument) { try? SMAppService.mainApp.register() }
        commands.start(); refreshLogin(); if updates { updater.start() }
        workspace.adopt(CommandLine.arguments); workspace.restore(); browser.restore()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.openedByURL else { return }
            self.workspace.welcomeIfNeeded()
        }
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
            item("About FairyStack", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(), item("Add Stack by Address…", #selector(WorkspaceWindows.changeAddress), "", target: workspace),
            .separator(), item("Hide FairyStack", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(), item("Quit FairyStack", #selector(quit), "q", target: self)]))
        if let menu = main.items.first?.submenu, let anchor = menu.items.first { workspace.installStackMenu(in: menu, before: anchor) }
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")]))
        main.addItem(submenu("View", [
            item("Reload", #selector(reloadActiveWindow), "r", target: self),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])]))
        main.addItem(submenu("Browser", [
            item("Browser Window", #selector(BrowserWindows.show), "1", target: browser),
            item("New Tab", #selector(BrowserWindows.newTab), "t", target: browser),
            item("Address or Search", #selector(BrowserWindows.focusAddress), "l", target: browser),
            item("Bookmark This Page", #selector(BrowserWindows.toggleBookmark), "d", target: browser),
            item("Bookmarks", #selector(BrowserWindows.showBookmarks), "b", [.command,.shift], target: browser),
            item("Back", #selector(BrowserWindows.goBack), "[", target: browser),
            item("Forward", #selector(BrowserWindows.goForward), "]", target: browser),
            item("Share Page to FairyStack", #selector(BrowserWindows.shareCurrentPage), "", target: browser),
            item("Open in Default Browser", #selector(BrowserWindows.openInDefaultBrowser), "", target: browser)]))
        main.addItem(submenu("Window", [
            item("New FairyStack Window", #selector(WorkspaceWindows.newWindow), "n", target: workspace),
            item("FairyStack Window", #selector(WorkspaceWindows.show), "0", target: workspace),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(closeActiveWindow), "w", target: self)]))
        return main
    }
    @objc private func reloadActiveWindow() { if browser.isKeyWindow { browser.reload() } else { workspace.reload() } }
    @objc private func closeActiveWindow() { if browser.isKeyWindow { browser.closeTab() } else { NSApp.keyWindow?.performClose(nil) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting or updating keeps the window's open state, so the next launch shows it again.
        browser.prepareToQuit(); workspace.terminating = true
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { workspace.finishDiagnostics(); commands.stop() }
    @objc private func checkUpdates() {
        // A background download must never terminate a window that owns microphone capture.
        // Manual restart remains available; automatic activation waits for idle.
        if updater.stagedVersion != nil { restart() } else { updater.check(announce: true) }
    }
    private func refreshLogin() { loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register(); if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } }
        } catch { let a = NSAlert(); a.messageText = "Login item failed"; a.informativeText = error.localizedDescription; a.runModal() }
        refreshLogin()
    }
    private func scheduleUpdateActivation() {
        updateActivationTimer?.invalidate()
        updateActivationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.activateUpdateWhenIdle() }
        activateUpdateWhenIdle()
    }
    private func activateUpdateWhenIdle() {
        guard updater.stagedVersion != nil, !checkingUpdateActivation else { return }
        updateItem.title = "Update ready · waiting for recording or browser work to finish"
        guard !commands.preventsUpdateRestart, !browser.preventsUpdateRestart else { return }
        checkingUpdateActivation = true
        workspace.canRestartForUpdate { [weak self] ready in
            guard let self else { return }
            self.checkingUpdateActivation = false
            guard ready, !self.commands.preventsUpdateRestart, !self.browser.preventsUpdateRestart else { return }
            self.restart()
        }
    }
    private func restart() {
        updateActivationTimer?.invalidate(); updateActivationTimer = nil
        relaunch(Bundle.main.bundleURL, arguments: workspace.resumeArguments) { [weak self] in self?.updateItem.title = "Update installed · quit and reopen to finish" }
    }
    /// Quits, then a detached helper opens `bundle` once this process is gone. Old and new builds never
    /// run side by side, and no deadline can kill a new build that is slow to pass its first-launch checks.
    private func relaunch(_ bundle: URL, arguments: [String], failed: @escaping () -> Void) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", relaunchScript, "fairystack-relaunch", String(ProcessInfo.processInfo.processIdentifier), "/usr/bin/open", bundle.path] + arguments
        helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { failed(); return }
        commands.stop(); NSApp.terminate(nil)
    }
    @objc private func quit() { commands.stop(); NSApp.terminate(nil) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
