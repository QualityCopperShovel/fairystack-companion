import AppKit
import UniformTypeIdentifiers
import WebKit

// FairyStack in a native window. The page announces the image under the pointer
// (with a short-lived signed original URL); pressing and dragging it starts a
// Finder file promise that downloads the original, which Chrome app windows cannot do.

enum WorkspaceAddress {
    static let defaultsKey = "workspaceOrigin"
    /// The public one-hour trial; fairystack.com's Try it button downloads this app to reach it.
    static let trialOrigin = URL(string: "https://trial-01.fairystack.com")!
    static func parse(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              let host = parts.host?.lowercased(), host.contains("."), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        var origin = URLComponents(); origin.scheme = "https"; origin.host = host; origin.port = parts.port
        return origin.url
    }
    /// fairystack://open?origin=https://you.fairystack.com — how a stack's Mac page hands its address to a downloaded app.
    static func fromOpenURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "fairystack", url.host?.lowercased() == "open",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "origin" })?.value,
              let origin = parse(value), origin.host != "fairystack.com" else { return nil }
        return origin
    }
    static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == origin.host && url.port == origin.port
    }
}

struct DraggableImage {
    static let types: [String: UTType] = ["image/png": .png, "image/jpeg": .jpeg, "image/webp": .webP]
    let url: URL
    let filename: String
    let type: UTType
    let rect: CGRect
    let expires: Date?

    init?(_ body: Any, origin: URL) {
        guard let body = body as? [String: Any], let text = body["url"] as? String, let url = URL(string: text),
              WorkspaceAddress.sameOrigin(url, origin), let name = body["filename"] as? String,
              name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$", options: .regularExpression) != nil,
              let mime = body["mime_type"] as? String, let type = DraggableImage.types[mime],
              let rect = body["rect"] as? [String: Double], let x = rect["x"], let y = rect["y"],
              let width = rect["width"], let height = rect["height"], width > 0, height > 0 else { return nil }
        self.url = url; filename = name; self.type = type
        self.rect = CGRect(x: x, y: y, width: width, height: height)
        expires = (body["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }
    var isFresh: Bool { expires.map { $0.timeIntervalSinceNow > 5 } ?? true }
}

// `failed` is only touched on the main queue; the session and queue are thread-safe.
final class ImageFileDragSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate, @unchecked Sendable {
    var failed: (String) -> Void = { _ in }
    private let queue: OperationQueue = { let queue = OperationQueue(); queue.qualityOfService = .userInitiated; return queue }()
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    // Finder calls the promise methods on `queue`, off the main thread.
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? DraggableImage)?.filename ?? "image"
    }
    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo destination: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let image = provider.userInfo as? DraggableImage else { return finish(completionHandler, "The dragged image lost its source.") }
        let finish = self.finish
        session.downloadTask(with: image.url) { file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { return finish(completionHandler, "Downloading \(image.filename) failed: \(error.localizedDescription)") }
            guard status == 200, let file else { return finish(completionHandler, "Downloading \(image.filename) failed (HTTP \(status)). Hover the image again and retry.") }
            do { try FileManager.default.moveItem(at: file, to: destination); completionHandler(nil) }
            catch { finish(completionHandler, "Saving \(image.filename) failed: \(error.localizedDescription)") }
        }.resume()
    }
    nonisolated private func finish(_ completion: (Error?) -> Void, _ message: String) {
        DispatchQueue.main.async { self.failed(message) }
        completion(NSError(domain: "FairyStackImageDrag", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

final class WorkspaceWebView: WKWebView {
    var draggable: DraggableImage?
    let dragSource = ImageFileDragSource()
    private var pressed: (event: NSEvent, image: DraggableImage)?
    lazy var startDrag: (NSEvent, DraggableImage) -> Void = { [unowned self] down, image in self.beginFileDrag(down, image) }

    private func cssPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let scale = max(pageZoom * magnification, 0.01)
        return CGPoint(x: point.x / scale, y: (isFlipped ? point.y : bounds.height - point.y) / scale)
    }
    private(set) var presses = 0, lastPressPoint = CGPoint.zero
    override func mouseDown(with event: NSEvent) {
        presses += 1; lastPressPoint = cssPoint(event)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.clickCount == 1, modifiers.isEmpty, let image = draggable, image.isFresh, image.rect.contains(cssPoint(event)) {
            pressed = (event, image); return  // Held until the pointer moves (drag) or releases (replayed click).
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press = pressed else { super.mouseDragged(with: event); return }
        let down = press.event, image = press.image
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) >= 4 else { return }
        pressed = nil
        startDrag(down, image)
    }
    private func beginFileDrag(_ down: NSEvent, _ image: DraggableImage) {
        let provider = NSFilePromiseProvider(fileType: image.type.identifier, delegate: dragSource)
        provider.userInfo = image
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(for: image.type); icon.size = NSSize(width: 64, height: 64)
        let start = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: start.x - 32, y: start.y - 32, width: 64, height: 64), contents: icon)
        beginDraggingSession(with: [item], event: down, source: dragSource)
    }
    override func mouseUp(with event: NSEvent) {
        guard let down = pressed?.event else { super.mouseUp(with: event); return }
        pressed = nil
        super.mouseDown(with: down); super.mouseUp(with: event)
    }
}

public final class WorkspaceWindows: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let dragMessage = "fairystackDrag"
    static let openKey = "workspaceWindowOpen"
    private let version: String
    private let pairedOrigin: () -> URL?
    private var pages: [(window: NSWindow, view: WorkspaceWebView, title: NSKeyValueObservation)] = []
    private var downloads: [ObjectIdentifier: URL] = [:]
    private lazy var content: WKUserContentController = {
        let controller = WKUserContentController()
        controller.add(WeakMessageHandler(self), name: Self.dragMessage)
        return controller
    }()

    public init(version: String, pairedOrigin: @escaping () -> URL?) { self.version = version; self.pairedOrigin = pairedOrigin }

    /// Set only for this launch when the owner chooses the trial.
    private var trialSession: URL?
    var origin: URL? {
        UserDefaults.standard.string(forKey: WorkspaceAddress.defaultsKey).flatMap(WorkspaceAddress.parse) ?? pairedOrigin() ?? trialSession
    }
    /// Arguments that let a relaunched build reopen exactly what this one shows.
    public var resumeArguments: [String] {
        guard let page = current, let url = page.view.url, let origin, WorkspaceAddress.sameOrigin(url, origin) else { return [] }
        return ["--fairystack-resume", url.absoluteString] + (NSApp.isActive ? ["--fairystack-activate"] : [])
    }
    /// Set once the app starts quitting: windows AppKit closes on the way out were not closed by the owner.
    public var terminating = false
    private var resumeURL: URL?
    private var activateOnResume = false
    public func adopt(_ arguments: [String]) {
        if let index = arguments.firstIndex(of: "--fairystack-resume"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]), let origin, WorkspaceAddress.sameOrigin(url, origin) {
            resumeURL = url; activateOnResume = arguments.contains("--fairystack-activate")
        }
        guard let index = arguments.firstIndex(of: "--fairystack-origin"), index + 1 < arguments.count,
              UserDefaults.standard.string(forKey: WorkspaceAddress.defaultsKey) == nil,
              let url = WorkspaceAddress.parse(arguments[index + 1]), url.host != "fairystack.com" else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: WorkspaceAddress.defaultsKey)
    }
    public func restore() {
        if let url = resumeURL {
            // An update relaunch: reopen the same page, in front only if the old build was.
            resumeURL = nil
            open(URLRequest(url: url, timeoutInterval: 30), configuration: nil, activate: activateOnResume)
            return
        }
        if origin != nil && UserDefaults.standard.object(forKey: Self.openKey) as? Bool != false { show() }
    }
    /// First launch from a download has no address yet: ask for it instead of sitting silently in the menu bar.
    public func welcomeIfNeeded() {
        if origin == nil && pages.isEmpty { show() }
    }
    public func handleOpenURL(_ url: URL) {
        guard let target = WorkspaceAddress.fromOpenURL(url) else { alert("Link not opened", "That FairyStack link is not a valid address.", for: nil); return }
        if target != origin {
            NSApp.activate(ignoringOtherApps: true)
            // Any web page can open this link, so switching addresses needs the owner's consent.
            let confirm = NSAlert(); confirm.messageText = "Open FairyStack at \(target.host ?? "")?"
            confirm.informativeText = "The FairyStack window will use this address from now on. Continue only if you started this from your own FairyStack."
            confirm.addButton(withTitle: "Open"); confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(target.absoluteString, forKey: WorkspaceAddress.defaultsKey)
            for page in pages { page.window.close() }
        }
        show()
    }
    @objc public func show() {
        if let page = pages.first { NSApp.setActivationPolicy(.regular); page.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let origin = origin ?? askForAddress(current: nil) else { return }
        open(URLRequest(url: origin.appendingPathComponent("workspace/"), timeoutInterval: 30), configuration: nil)
    }
    @objc public func changeAddress() {
        guard let url = askForAddress(current: origin) else { return }
        for page in pages { page.window.close() }
        open(URLRequest(url: url.appendingPathComponent("workspace/"), timeoutInterval: 30), configuration: nil)
    }
    @objc public func reload() { current?.view.reload() }
    private var current: (window: NSWindow, view: WorkspaceWebView, title: NSKeyValueObservation)? {
        pages.first { $0.window.isKeyWindow } ?? pages.first
    }

    private func askForAddress(current: URL?) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = current == nil ? "Welcome to FairyStack" : "Open your FairyStack"
        alert.informativeText = current == nil
            ? "Try FairyStack free for an hour, or enter your own FairyStack address, for example you.fairystack.com."
            : "Enter your FairyStack address, for example you.fairystack.com."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = current?.absoluteString ?? ""; field.placeholderString = "https://you.fairystack.com"
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        if current == nil { alert.addButton(withTitle: "Try FairyStack") }
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        var choice = alert.runModal()
        if current == nil {
            if choice == .alertFirstButtonReturn {
                // The trial address is not saved: after the hour, the next launch asks again for the new stack.
                trialSession = WorkspaceAddress.trialOrigin; return WorkspaceAddress.trialOrigin
            }
            choice = NSApplication.ModalResponse(rawValue: choice.rawValue - 1)
        }
        guard choice == .alertFirstButtonReturn else { return nil }
        guard let url = WorkspaceAddress.parse(field.stringValue) else {
            let error = NSAlert(); error.messageText = "That is not a FairyStack address"
            error.informativeText = "Use an HTTPS address with no path, like https://you.fairystack.com."; error.runModal()
            return nil
        }
        UserDefaults.standard.set(url.absoluteString, forKey: WorkspaceAddress.defaultsKey)
        return url
    }

    @discardableResult
    private func open(_ request: URLRequest?, configuration: WKWebViewConfiguration?, activate: Bool = true) -> WorkspaceWebView {
        let config = configuration ?? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.userContentController = content
            config.applicationNameForUserAgent = "FairyStackMac/\(version)"
            config.preferences.isElementFullscreenEnabled = true
            return config
        }()
        let view = WorkspaceWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 860), configuration: config)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.dragSource.failed = { [weak self, weak view] message in self?.alert("Image not saved", message, for: view?.window) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.title = "FairyStack"; window.contentView = view; window.delegate = self
        if pages.isEmpty { if !window.setFrameUsingName("FairyStackWorkspace") { window.center() }; window.setFrameAutosaveName("FairyStackWorkspace") }
        else if let last = pages.last?.window { window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY))) }
        let title = view.observe(\.title) { [weak window] view, _ in window?.title = (view.title ?? "").isEmpty ? "FairyStack" : view.title! }
        pages.append((window, view, title))
        if let request { view.load(request) }
        UserDefaults.standard.set(true, forKey: Self.openKey)
        NSApp.setActivationPolicy(.regular)
        if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { window.orderFront(nil) }
        return view
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let index = pages.firstIndex(where: { $0.window === window }) else { return }
        pages[index].view.stopLoading(); pages.remove(at: index)
        if pages.isEmpty {
            if !terminating { UserDefaults.standard.set(false, forKey: Self.openKey) }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func allowedInWindow(_ url: URL) -> Bool {
        guard let origin else { return false }
        if WorkspaceAddress.sameOrigin(url, origin) { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "authreturn.com" || host.hasSuffix(".authreturn.com")
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.dragMessage, let view = message.webView as? WorkspaceWebView,
              let origin, message.frameInfo.isMainFrame else { return }
        view.draggable = DraggableImage(message.body, origin: origin)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.targetFrame?.isMainFrame == false || ["about", "blob", "data"].contains(url.scheme ?? "") || allowedInWindow(url) {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url); decisionHandler(.cancel)
    }
    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType ? .download : .allow)
    }
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(webView, error) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(webView, error) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    private func loadFailed(_ webView: WKWebView, _ error: Error) {
        let error = error as NSError
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        let retry = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? origin?.appendingPathComponent("workspace/")
        let escape = { (text: String) in text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>FairyStack is unreachable</title>
        <style>:root{color:#17211c;background:#edf7f1}@media(prefers-color-scheme:dark){:root{color:#e6efe9;background:#141c18}a{color:#9fd8b4}}
        body{font:15px -apple-system,system-ui;margin:18vh auto;max-width:520px;padding:0 24px}a{color:#1f6b45}</style>
        <h1>FairyStack could not load</h1><p>\(escape(error.localizedDescription))</p>
        <p><a href="\(escape(retry?.absoluteString ?? "about:blank"))">Retry</a> or press ⌘R.</p>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        guard allowedInWindow(url) else { NSWorkspace.shared.open(url); return nil }
        return open(nil, configuration: configuration)
    }
    public func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories; panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let window = webView.window else { return completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = message
        present(alert, webView) { _ in completionHandler() }
    }
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        present(alert, webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = defaultText ?? ""; alert.accessoryView = field
        present(alert, webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    private func present(_ alert: NSAlert, _ webView: WKWebView, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }
    private func alert(_ title: String, _ message: String, for window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = (suggestedFilename as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "download" }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        for n in 2...999 where FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else { return completionHandler(nil) }
        downloads[ObjectIdentifier(download)] = target; completionHandler(target)
    }
    public func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
    }
    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let file = downloads.removeValue(forKey: ObjectIdentifier(download))
        alert("Download failed", "\(file?.lastPathComponent ?? "The file") was not saved: \(error.localizedDescription)", for: download.webView?.window)
    }
}

// WKUserContentController retains its handlers; this breaks the cycle with the window manager.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
