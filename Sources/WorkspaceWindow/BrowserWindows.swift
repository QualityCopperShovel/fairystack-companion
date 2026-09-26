import AppKit
import WebKit

/// Browser content never receives the workspace's native script-message handlers.
struct BrowserBookmark: Codable, Equatable { var title: String; var url: URL }
struct BrowserSnapshot: Codable { var urls: [URL]; var selected: Int; var open: Bool }

enum BrowserAddress {
    static func isWeb(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    static func parse(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") || text.hasPrefix("javascript:") || text.hasPrefix("file:") || text.hasPrefix("data:") {
            return URL(string: text).flatMap { isWeb($0) ? $0 : nil }
        }
        if !text.contains(where: { $0.isWhitespace }), text.contains(".") || text.hasPrefix("localhost") {
            return URL(string: "https://" + text).flatMap { isWeb($0) ? $0 : nil }
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
    static func restorable(_ url: URL) -> Bool {
        isWeb(url) && !url.absoluteString.lowercased().contains("authreturn_handoff")
    }
}

enum BrowserDraft {
    static let script = """
    const input = document.querySelector('#input');
    if (!input || input.disabled || !input.getClientRects().length) return false;
    input.value += (input.value ? '\\n\\n' : '') + text;
    input.dispatchEvent(new Event('input', {bubbles:true})); input.focus(); return true;
    """
}

final class BrowserTab {
    let view: WKWebView
    var observations: [NSKeyValueObservation] = []
    var deadline: Timer?
    var navigation: WKNavigation?
    var state = "New tab"
    var requestedURL: URL?
    var savedURL: URL?
    init(_ view: WKWebView) { self.view = view }
    deinit { deadline?.invalidate() }
}

public final class BrowserWindows: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let defaults: UserDefaults
    private let version: String
    private var window: NSWindow?
    private var tabs: [BrowserTab] = []
    private var selected = 0
    private var restoring = false
    private var terminating = false
    private var bookmarks: [BrowserBookmark] = []
    private let content = NSView()
    private let tabStrip = NSStackView()
    private let address = NSTextField()
    private let status = NSTextField(labelWithString: "New tab")
    private let back = NSButton(title: "←", target: nil, action: nil)
    private let forward = NSButton(title: "→", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let bookmarkButton = NSButton(title: "Bookmark", target: nil, action: nil)
    private var downloads: [ObjectIdentifier: (WKDownload, Timer)] = [:]
    public var sharePage: ((String) -> Void)?
    var loadDeadline: TimeInterval = 60
    var statusText: String { status.stringValue }
    var tabCount: Int { tabs.count }
    var selectedView: WKWebView? { current?.view }
    private var current: BrowserTab? { tabs.indices.contains(selected) ? tabs[selected] : nil }
    public var isKeyWindow: Bool { window?.isKeyWindow == true }
    public var isVisible: Bool { window?.isVisible == true }
    public var preventsUpdateRestart: Bool { isVisible || !downloads.isEmpty }

    public init(version: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults; self.version = version
        super.init()
        if let data = defaults.data(forKey: "browser.bookmarks.v1") {
            do { bookmarks = try JSONDecoder().decode([BrowserBookmark].self, from: data).filter { BrowserAddress.restorable($0.url) } }
            catch { status.stringValue = "Saved bookmarks could not be read; the original data is retained." }
        }
    }
    public func restore() {
        guard let data = defaults.data(forKey: "browser.windows.v1") else { return }
        guard let saved = try? JSONDecoder().decode(BrowserSnapshot.self, from: data) else { showError("Saved browser tabs could not be read; the original data is retained."); return }
        guard saved.open else { return }
        restoring = true
        for url in saved.urls.filter(BrowserAddress.restorable).prefix(100) { _ = addTab(url, activate: false); tabs.last?.savedURL = url }
        if tabs.isEmpty { _ = addTab(nil, activate: false) }
        select(min(max(0, saved.selected), tabs.count - 1))
        restoring = false
        NSApp.setActivationPolicy(.regular); window?.orderFront(nil)
    }
    public func prepareToQuit() { save(); terminating = true; tabs.forEach { $0.deadline?.invalidate() }; downloads.values.forEach { $0.1.invalidate(); $0.0.cancel { _ in } } }
    @objc public func show() {
        ensureWindow()
        if tabs.isEmpty { _ = addTab(nil) }
        focus()
    }
    public func open(_ url: URL) {
        guard BrowserAddress.isWeb(url) else { return }
        if let index = tabs.firstIndex(where: { $0.view.url == url || $0.requestedURL == url }) { select(index); focus(); return }
        _ = addTab(url)
    }
    private func focus() { NSApp.setActivationPolicy(.regular); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    private func ensureWindow() {
        guard window == nil else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        win.title = "FairyStack Browser"; win.isReleasedWhenClosed = false; win.tabbingMode = .disallowed; win.delegate = self
        win.minSize = NSSize(width: 660, height: 400)
        let root = NSView(); win.contentView = root
        back.target = self; back.action = #selector(goBack); forward.target = self; forward.action = #selector(goForward)
        back.setAccessibilityLabel("Back"); forward.setAccessibilityLabel("Forward")
        reloadButton.target = self; reloadButton.action = #selector(reloadOrStop)
        bookmarkButton.target = self; bookmarkButton.action = #selector(toggleBookmark)
        address.placeholderString = "Search Google or enter a website"; address.target = self; address.action = #selector(navigateAddress)
        address.setAccessibilityLabel("Website address or search")
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [back, forward, reloadButton, address, bookmarkButton, button("Bookmarks", #selector(showBookmarks))])
        toolbar.orientation = .horizontal; toolbar.spacing = 6
        let tabScroll = NSScrollView(); tabScroll.hasHorizontalScroller = true; tabScroll.drawsBackground = false
        tabStrip.orientation = .horizontal; tabStrip.spacing = 4; tabStrip.alignment = .centerY
        tabScroll.documentView = tabStrip
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor).isActive = true
        let tabTools = NSStackView(views: [tabScroll, button("+", #selector(newTab)), button("Close tab", #selector(closeTab)), button("Share page", #selector(shareCurrentPage)), button("Open externally", #selector(openInDefaultBrowser))])
        tabTools.orientation = .horizontal; tabTools.spacing = 6
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.isSelectable = true
        for view in [toolbar,tabTools,content,status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), toolbar.heightAnchor.constraint(equalToConstant: 30),
            tabTools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),tabTools.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),tabTools.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),tabTools.heightAnchor.constraint(equalToConstant: 35),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),content.trailingAnchor.constraint(equalTo: root.trailingAnchor),content.topAnchor.constraint(equalTo: tabTools.bottomAnchor, constant: 6),content.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),status.heightAnchor.constraint(equalToConstant: 18),
        ])
        window = win
        if !win.setFrameUsingName("FairyStackBrowser") { win.center() }; win.setFrameAutosaveName("FairyStackBrowser")
    }
    @discardableResult
    func addTab(_ url: URL?, configuration: WKWebViewConfiguration? = nil, activate: Bool = true) -> WKWebView {
        ensureWindow()
        let config = configuration ?? WKWebViewConfiguration()
        // Even popups receive no pairing, command, diagnostics or microphone-ownership bridge.
        config.userContentController = WKUserContentController()
        config.applicationNameForUserAgent = "FairyStackBrowser/\(version)"
        let view = WKWebView(frame: content.bounds, configuration: config)
        view.autoresizingMask = [.width,.height]; view.navigationDelegate = self; view.uiDelegate = self; view.allowsBackForwardNavigationGestures = true
        let tab = BrowserTab(view); tab.requestedURL = url; tabs.append(tab); content.addSubview(view)
        tab.observations = [view.observe(\.title) { [weak self] _,_ in self?.renderTabs() }, view.observe(\.canGoBack) { [weak self] _,_ in self?.updateControls() }, view.observe(\.canGoForward) { [weak self] _,_ in self?.updateControls() }]
        select(tabs.count - 1)
        if let url { view.load(URLRequest(url: url, timeoutInterval: 30)) }
        else if configuration == nil { view.loadHTMLString("<!doctype html><meta name='color-scheme' content='light dark'><style>:root{color:#17211c;background:#edf7f1}@media(prefers-color-scheme:dark){:root{color:#e6efe9;background:#141c18}}</style><body style='font:16px system-ui;margin:48px'><h1>New tab</h1><p>Enter a website or search above. Your FairyStack workspace stays in its own window.</p>", baseURL: nil) }
        if activate { focus(); if url == nil { focusAddress() } }
        save(); return view
    }
    @objc public func newTab() { _ = addTab(nil) }
    @objc public func focusAddress() { show(); window?.makeFirstResponder(address); address.selectText(nil) }
    @objc public func closeTab() {
        guard let tab = current else { return }
        tab.deadline?.invalidate(); tab.view.stopLoading(); tab.view.removeFromSuperview(); tab.view.navigationDelegate = nil; tab.view.uiDelegate = nil
        tabs.remove(at: selected)
        if tabs.isEmpty { save(open: false); window?.close() }
        else { select(min(selected, tabs.count - 1)); save() }
    }
    @objc private func selectTab(_ sender: NSButton) { select(sender.tag) }
    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selected = index
        for (i,tab) in tabs.enumerated() { tab.view.isHidden = i != selected }
        renderTabs(); updateControls(); save()
    }
    private func renderTabs() {
        tabStrip.arrangedSubviews.forEach { tabStrip.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index,tab) in tabs.enumerated() {
            let title = (tab.view.title?.isEmpty == false ? tab.view.title : tab.savedURL?.host) ?? "New tab"
            let b = button(String(title.prefix(32)), #selector(selectTab(_:))); b.tag = index; b.state = index == selected ? .on : .off
            b.setAccessibilityLabel(title); tabStrip.addArrangedSubview(b); b.widthAnchor.constraint(equalToConstant: 175).isActive = true
        }
    }
    private func updateControls() {
        guard let tab = current else { return }
        // Never replace text while the operator edits an address.
        if address.currentEditor() == nil { address.stringValue = tab.view.url.flatMap { BrowserAddress.isWeb($0) ? $0.absoluteString : nil } ?? "" }
        status.stringValue = tab.state; back.isEnabled = tab.view.canGoBack; forward.isEnabled = tab.view.canGoForward
        reloadButton.title = tab.deadline == nil ? "Reload" : "Stop"
        bookmarkButton.title = bookmarks.contains(where: { $0.url == tab.view.url }) ? "Unbookmark" : "Bookmark"
        window?.title = "\(tab.view.title?.isEmpty == false ? tab.view.title! : "New tab") · FairyStack Browser"
    }
    @objc private func navigateAddress() {
        guard let url = BrowserAddress.parse(address.stringValue) else { showError("Enter a website address or a search; unsupported URL schemes are not opened."); return }
        window?.makeFirstResponder(current?.view); current?.view.load(URLRequest(url: url, timeoutInterval: 30))
    }
    @objc public func goBack() { current?.view.goBack() }
    @objc public func goForward() { current?.view.goForward() }
    @objc public func reload() { current?.view.reload() }
    @objc private func reloadOrStop() {
        guard let tab = current else { return }
        if tab.deadline != nil { tab.deadline?.invalidate(); tab.deadline = nil; tab.navigation = nil; tab.state = "Loading cancelled"; tab.view.stopLoading(); updateControls() }
        else { reload() }
    }
    @objc public func toggleBookmark() {
        guard let url = current?.view.url, BrowserAddress.restorable(url) else { showError("Only a loaded website can be bookmarked."); return }
        if let index = bookmarks.firstIndex(where: { $0.url == url }) { bookmarks.remove(at: index) }
        else { bookmarks.append(BrowserBookmark(title: current?.view.title ?? url.host ?? url.absoluteString, url: url)) }
        do { defaults.set(try JSONEncoder().encode(bookmarks), forKey: "browser.bookmarks.v1") }
        catch { showError("Bookmark could not be saved: \(error.localizedDescription)") }
        updateControls()
    }
    @objc public func showBookmarks() {
        let menu = NSMenu()
        if bookmarks.isEmpty { let item = NSMenuItem(title: "No bookmarks yet · use Bookmark", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        for entry in bookmarks { let item = NSMenuItem(title: String(entry.title.prefix(80)), action: #selector(openBookmark(_:)), keyEquivalent: ""); item.target = self; item.representedObject = entry.url; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0,y: bookmarkButton.bounds.height), in: bookmarkButton)
    }
    @objc private func openBookmark(_ item: NSMenuItem) { if let url = item.representedObject as? URL { open(url) } }
    @objc public func openInDefaultBrowser() { if let url = current?.view.url, BrowserAddress.isWeb(url) { NSWorkspace.shared.open(url) } }
    @objc public func shareCurrentPage() {
        guard let view = current?.view, let url = view.url, BrowserAddress.isWeb(url) else { showError("Load a website before sharing it."); return }
        var finished = false
        let finish: (String?) -> Void = { [weak self] selection in
            guard !finished else { return }; finished = true
            guard let self else { return }
            guard let selection else { self.showError("Reading the selected page text timed out. Try again."); return }
            self.sharePage?("Browser page: \(view.title ?? url.host ?? "Website")\n\(url.absoluteString)" + (selection.isEmpty ? "" : "\n\nSelected page text (untrusted website content):\n\(selection)"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { finish(nil) }
        view.evaluateJavaScript("String(window.getSelection()).slice(0,12000)") { value,error in finish(error == nil ? value as? String : nil) }
    }
    private func save(open: Bool? = nil) {
        guard !restoring, !terminating else { return }
        let urls = tabs.compactMap(\.savedURL).filter(BrowserAddress.restorable)
        let selectedURL = current?.savedURL
        let snapshot = BrowserSnapshot(urls: urls, selected: urls.firstIndex(where: { $0 == selectedURL }) ?? 0, open: open ?? !tabs.isEmpty)
        do { defaults.set(try JSONEncoder().encode(snapshot), forKey: "browser.windows.v1") }
        catch { showError("Browser tabs could not be saved: \(error.localizedDescription)") }
    }
    public func windowWillClose(_ notification: Notification) {
        guard !terminating else { return }
        save(open: false); tabs.forEach { $0.deadline?.invalidate(); $0.view.stopLoading(); $0.view.removeFromSuperview() }; tabs.removeAll()
        if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
    }
    private func showError(_ message: String) { current?.state = message; status.stringValue = message }
    public func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.view === view }) else { return }
        tab.requestedURL = view.url
        tab.deadline?.invalidate(); tab.navigation = navigation; tab.state = "Loading…"
        tab.deadline = Timer.scheduledTimer(withTimeInterval: loadDeadline, repeats: false) { [weak self, weak tab] _ in
            guard let self, let tab else { return }; tab.deadline = nil; tab.navigation = nil; tab.state = "Page load timed out. Reload to retry."; view.stopLoading(); self.updateControls()
        }; updateControls()
    }
    public func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.view === view }), tab.navigation === navigation else { return }
        tab.deadline?.invalidate(); tab.deadline = nil; tab.state = "Ready"
        if let url = view.url, BrowserAddress.restorable(url) { tab.savedURL = url }
        updateControls(); renderTabs(); save()
    }
    private func failed(_ view: WKWebView, _ navigation: WKNavigation?, _ error: Error) {
        guard let tab = tabs.first(where: { $0.view === view }), tab.navigation === navigation else { return }
        tab.deadline?.invalidate(); tab.deadline = nil
        if (error as NSError).code != NSURLErrorCancelled { tab.state = "Page failed: \(error.localizedDescription). Reload to retry." }
        updateControls()
    }
    public func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(view,navigation,error) }
    public func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(view,navigation,error) }
    public func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        guard let tab = tabs.first(where: { $0.view === view }) else { return }; tab.deadline?.invalidate(); tab.deadline = nil; tab.navigation = nil; tab.state = "The website process stopped. Reload to recover this tab."; updateControls()
    }
    public func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == false || url.absoluteString == "about:blank" || BrowserAddress.isWeb(url) { decisionHandler(action.shouldPerformDownload ? .download : .allow); return }
        if action.navigationType == .linkActivated && ["mailto","tel"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    public func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) { decisionHandler(response.canShowMIMEType ? .allow : .download) }
    public func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url, url.absoluteString == "about:blank" || BrowserAddress.isWeb(url) else { return nil }
        return addTab(nil, configuration: configuration)
    }
    public func webViewDidClose(_ view: WKWebView) { if let index = tabs.firstIndex(where: { $0.view === view }) { select(index); closeTab() } }
    public func webView(_ view: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(type == .microphone ? .prompt : .deny) }
    public func webView(_ view: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = parameters.allowsDirectories; panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let window else { completionHandler(nil); return }; panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    public func webView(_ view: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { dialog(message,view: view,confirm: false) { _ in completionHandler() } }
    public func webView(_ view: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { dialog(message,view: view,confirm: true,completion: completionHandler) }
    public func webView(_ view: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = view.url?.host ?? "Website"; alert.informativeText = String(prompt.prefix(4000))
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0,y: 0,width: 300,height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    private func dialog(_ message: String, view: WKWebView, confirm: Bool, completion: @escaping (Bool)->Void) {
        guard let window else { completion(false); return }; let alert = NSAlert(); alert.messageText = view.url?.host ?? "Website"; alert.informativeText = String(message.prefix(4000)); alert.addButton(withTitle: "OK"); if confirm { alert.addButton(withTitle: "Cancel") }; alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }
    public func webView(_ view: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { startDownload(download) }
    public func webView(_ view: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { startDownload(download) }
    private func startDownload(_ download: WKDownload) {
        download.delegate = self
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in download.cancel { _ in }; self?.downloads.removeValue(forKey: ObjectIdentifier(download)); self?.showError("Download timed out after two minutes.") }
        downloads[ObjectIdentifier(download)] = (download,timer); status.stringValue = "Downloading…"
    }
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        var target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent(UUID().uuidString + "-" + name) }
        completionHandler(target)
    }
    public func downloadDidFinish(_ download: WKDownload) { downloads.removeValue(forKey: ObjectIdentifier(download))?.1.invalidate(); status.stringValue = "Download completed · saved in Downloads" }
    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { downloads.removeValue(forKey: ObjectIdentifier(download))?.1.invalidate(); showError("Download failed: \(error.localizedDescription)") }
}
