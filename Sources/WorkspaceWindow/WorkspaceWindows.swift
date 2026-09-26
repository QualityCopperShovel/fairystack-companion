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
              let host = parts.host?.lowercased(), host.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\\.[a-z0-9-]+$", options: .regularExpression) != nil, !host.contains(".."),
              (parts.port == nil || (1...65535).contains(parts.port!)), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        var origin = URLComponents(); origin.scheme = "https"; origin.host = host; origin.port = parts.port == 443 ? nil : parts.port
        return origin.url
    }
    /// fairystack://open?origin=https://you.fairystack.com — how a stack's Mac page hands its address to a downloaded app.
    static func fromOpenURL(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "fairystack", parts.host?.lowercased() == "open",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty, let items = parts.queryItems, items.count == 1,
              items[0].name == "origin", let value = items[0].value,
              let origin = parse(value), origin.host != "fairystack.com", origin.host != "www.fairystack.com" else { return nil }
        return origin
    }
    static func sameOrigin(_ securityOrigin: WKSecurityOrigin, _ origin: URL) -> Bool {
        securityOrigin.protocol == "https" && securityOrigin.host.lowercased() == origin.host &&
            (securityOrigin.port == 0 ? 443 : securityOrigin.port) == (origin.port ?? 443)
    }
    static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.host?.lowercased() == origin.host && (url.port ?? 443) == (origin.port ?? 443)
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
        session = URLSession(configuration: configuration, delegate: ImageOriginRedirects(), delegateQueue: nil)
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
        guard image.isFresh else { return finish(completionHandler, "The image link expired. Hover the image again and retry.") }
        let finish = self.finish
        session.downloadTask(with: image.url) { file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { return finish(completionHandler, "Downloading \(image.filename) failed: \(error.localizedDescription)") }
            guard status == 200, let file, let finalURL = response?.url, finalURL.scheme == image.url.scheme, finalURL.host == image.url.host, (finalURL.port ?? 443) == (image.url.port ?? 443) else { return finish(completionHandler, "Downloading \(image.filename) failed (HTTP \(status)). Hover the image again and retry.") }
            do { try FileManager.default.moveItem(at: file, to: destination); completionHandler(nil) }
            catch { finish(completionHandler, "Saving \(image.filename) failed: \(error.localizedDescription)") }
        }.resume()
    }
    nonisolated private func finish(_ completion: (Error?) -> Void, _ message: String) {
        DispatchQueue.main.async { self.failed(message) }
        completion(NSError(domain: "FairyStackImageDrag", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

private final class ImageOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let next = request.url,
              next.scheme == "https", next.host == original.host, (next.port ?? 443) == (original.port ?? 443),
              next.user == nil, next.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

final class WorkspaceWebView: WKWebView {
    var workspaceOrigin: URL?
    var isAuxiliary = false
    weak var opener: WorkspaceWebView?
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

enum LocalPairingRequest {
    static func token(_ body: Any, frameURL: URL, origin: URL, mainFrame: Bool) -> String? {
        guard mainFrame, WorkspaceAddress.sameOrigin(frameURL, origin), frameURL.path == "/companions",
              let fields = body as? [String: String], fields.count == 1,
              let token = fields["token"], token.range(of: "^fs_mac_[A-Za-z0-9_-]{20,90}$", options: .regularExpression) != nil else { return nil }
        return token
    }
}

public final class WorkspaceWindows: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKDownloadDelegate, NSMenuDelegate {
    static let dragMessage = "fairystackDrag"
    public var connectLocal: ((URL, String, NSWindow, @escaping (String?) -> Void) -> Void)?
    static let openKey = "workspaceWindowOpen"
    private let version: String
    private let pairedOrigin: () -> URL?
    private let store: SavedStacks
    lazy var diagnostics = NativeDiagnostics(defaults: store.defaults, version: version)
    lazy var microphoneConsent = MicrophoneConsent(store: store)
    private var focusedView: WorkspaceWebView?
    let microphone = MicrophoneOwnership()
    // Read the existing page lifecycle owner; never restart during recording,
    // permission startup, uploads, or a cross-window microphone transfer.
    public func canRestartForUpdate(completion: @escaping (Bool) -> Void) {
        let views = (pages + auxiliaries).map { $0.view } + (microphone.owner.map { [$0] } ?? [])
        guard !microphoneConsent.hasPending, !microphone.isTransferring, views.allSatisfy({ $0.microphoneCaptureState == .none }) else {
            completion(false); return
        }
        guard !views.isEmpty else { completion(true); return }
        var remaining = views.count, finished = false
        let finish: (Bool) -> Void = { ready in
            guard !finished else { return }; finished = true
            completion(ready && !self.microphoneConsent.hasPending && !self.microphone.isTransferring && views.allSatisfy { $0.microphoneCaptureState == .none })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
        for view in views {
            view.evaluateJavaScript("document.readyState === 'complete' && !Boolean(window.FairyStackReloadGuard?.busy?.())") { value, error in
                guard !finished else { return }
                guard error == nil, value as? Bool == true else { finish(false); return }
                remaining -= 1
                if remaining == 0 { finish(true) }
            }
        }
    }

    private var restoring = false
    private var menuAnchors: [ObjectIdentifier: NSMenuItem] = [:]
    private var pages: [(window: NSWindow, view: WorkspaceWebView, title: NSKeyValueObservation)] = []
    private var auxiliaries: [(window: NSWindow, view: WorkspaceWebView, title: NSKeyValueObservation)] = []
    // Injectable LaunchServices boundary: internal bootstrap URLs must never reach it.
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private func launchExternal(_ url: URL) {
        guard ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return }
        openExternal(url)
    }
    private var downloads: [ObjectIdentifier: URL] = [:]
    private lazy var content: WKUserContentController = {
        let controller = WKUserContentController()
        controller.add(WeakMessageHandler(self), name: Self.dragMessage)
        controller.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: "fairystackDiagnostics")
        controller.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: "fairystackMicrophone")
        controller.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: "fairystackPair")
        controller.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: "fairystackConnect")
        return controller
    }()

    public init(version: String, pairedOrigin: @escaping () -> URL?, defaults: UserDefaults = .standard) {
        self.version = version; self.pairedOrigin = pairedOrigin; self.store = SavedStacks(defaults: defaults)
        super.init()
    }
    private var trialSession: URL?
    var origin: URL? { current?.view.workspaceOrigin ?? store.selected ?? trialSession }
    public var resumeArguments: [String] {
        persistWindows()
        return NSApp.isActive ? ["--fairystack-activate"] : []
    }
    public var terminating = false { didSet { if terminating { microphoneConsent.cancelAll(); persistWindows() } } }
    private var resumeURL: URL?
    private var activateOnResume = false
    public func finishDiagnostics() { diagnostics.finish() }
    public func adopt(_ arguments: [String]) {
        diagnostics.start()
        store.migrate(pairedOrigin: pairedOrigin()); store.seedDefault()
        activateOnResume = arguments.contains("--fairystack-activate")
        if let index = arguments.firstIndex(of: "--fairystack-origin"), index + 1 < arguments.count,
           let url = WorkspaceAddress.parse(arguments[index + 1]), url.host != "fairystack.com" {
            register(url)
        }
        // Compatibility with the previous updater. Only a previously saved stack may resume a URL.
        if let index = arguments.firstIndex(of: "--fairystack-resume"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]), store.entries.contains(where: { WorkspaceAddress.sameOrigin(url, $0.url) }) {
            resumeURL = url
        }
    }
    public func restore() {
        guard pages.isEmpty else { return } // An early URL handoff already opened its window.
        restoring = true
        let records = store.windows
        for record in records {
            open(URLRequest(url: record.url, timeoutInterval: 30), origin: record.origin, configuration: nil, activate: false)
        }
        if pages.isEmpty, let url = resumeURL, let stack = store.entries.first(where: { WorkspaceAddress.sameOrigin(url, $0.url) }) {
            open(URLRequest(url: url, timeoutInterval: 30), origin: stack.url, configuration: nil, activate: activateOnResume)
        } else if pages.isEmpty && !store.hasWindowSnapshot && store.defaults.object(forKey: Self.openKey) as? Bool != false, let origin = store.selected {
            openStack(origin, activate: activateOnResume)
        }
        if let selected = store.selected, let page = pages.first(where: { $0.view.workspaceOrigin == selected }) {
            focusedView = page.view
            if activateOnResume { focus(page.window) }
        }
        restoring = false; persistWindows()
    }
    public func welcomeIfNeeded() { if origin == nil && pages.isEmpty { show() } }
    private func register(_ target: URL) {
        if target == WorkspaceAddress.trialOrigin { trialSession = target } else { store.add(target) }
    }
    public func handleOpenURL(_ url: URL) {
        guard let target = WorkspaceAddress.fromOpenURL(url) else { alert("Link not opened", "That FairyStack link is not a valid address.", for: nil); return }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert(); confirm.messageText = "Open FairyStack at \(target.host ?? "")?"
        confirm.informativeText = "\(target.absoluteString)\n\nContinue only if you started this from your own FairyStack. This adds the stack to your menu; it does not pair Mac commands or transfer a sign-in."
        confirm.addButton(withTitle: "Open"); confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        register(target); openStack(target)
    }
    private func focus(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @discardableResult
    func openStack(_ target: URL, newWindow: Bool = false, activate: Bool = true) -> WorkspaceWebView {
        if !newWindow, let page = pages.first(where: { $0.view.workspaceOrigin == target }) {
            focusedView = page.view; store.select(target)
            if activate { focus(page.window) }; return page.view
        }
        return open(URLRequest(url: target.appendingPathComponent("workspace/"), timeoutInterval: 30), origin: target, configuration: nil, activate: activate)
    }
    @objc public func show() {
        if let current { focus(current.window); return }
        guard let target = origin ?? welcome() else { return }
        openStack(target)
    }
    @objc public func changeAddress() {
        guard let target = askForAddress(current: origin) else { return }
        openStack(target)
    }
    @objc public func newWindow() {
        guard let target = origin else { show(); return }; openStack(target, newWindow: true)
    }
    @objc public func reload() { current?.view.reload() }
    private var current: (window: NSWindow, view: WorkspaceWebView, title: NSKeyValueObservation)? {
        pages.first { $0.view === focusedView } ?? pages.first { $0.window.isKeyWindow } ?? pages.first
    }
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let page = pages.first(where: { $0.window === window }) else { return }
        focusedView = page.view
        if !restoring, let target = page.view.workspaceOrigin { store.select(target) }
    }
    public func installStackMenu(in menu: NSMenu, before anchor: NSMenuItem) {
        menuAnchors[ObjectIdentifier(menu)] = anchor; menu.delegate = self
    }
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard let anchor = menuAnchors[ObjectIdentifier(menu)] else { return }
        for item in menu.items where item.tag == 731 { menu.removeItem(item) }
        var index = menu.index(of: anchor)
        func insert(_ item: NSMenuItem) { item.tag = 731; menu.insertItem(item, at: index); index += 1 }
        func stackItem(_ entry: SavedStack, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: entry.name, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = entry.url.absoluteString
            if entry.name != SavedStacks.defaultName(entry.url) { item.title += " · " + SavedStacks.defaultName(entry.url) }
            item.state = entry.url == origin ? .on : .off; return item
        }
        let heading = NSMenuItem(title: "Your FairyStacks", action: nil, keyEquivalent: ""); insert(heading)
        for entry in store.entries { insert(stackItem(entry, action: #selector(selectStack(_:)))) }
        if store.entries.isEmpty { insert(NSMenuItem(title: "Add a stack from its onboarding page", action: nil, keyEquivalent: "")) }
        let fresh = NSMenuItem(title: "Open in New Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in store.entries { submenu.addItem(stackItem(entry, action: #selector(newStackWindow(_:)))) }
        fresh.submenu = submenu; fresh.isEnabled = !store.entries.isEmpty; insert(fresh)
        if let origin, origin != WorkspaceAddress.trialOrigin {
            for (title, action) in [("Rename this stack…", #selector(renameStack)), ("Forget this stack", #selector(forgetStack)), ("Reset microphone permission for this stack", #selector(resetMicrophonePermission))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; insert(item)
            }
        }
        insert(.separator())
        let paired = pairedOrigin()?.absoluteString ?? "Not paired"
        insert(NSMenuItem(title: "Mac commands · \(paired)", action: nil, keyEquivalent: ""))
        insert(.separator())
    }
    @objc private func selectStack(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String, let target = WorkspaceAddress.parse(text) else { return }
        openStack(target)
    }
    @objc private func newStackWindow(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String, let target = WorkspaceAddress.parse(text) else { return }
        openStack(target, newWindow: true)
    }
    @objc private func renameStack() {
        guard let origin, let entry = store.entries.first(where: { $0.url == origin }) else { return }
        let dialog = NSAlert(); dialog.messageText = "Name this FairyStack"; dialog.informativeText = origin.absoluteString
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); field.stringValue = entry.name
        dialog.accessoryView = field; dialog.addButton(withTitle: "Save"); dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        guard store.rename(origin, to: field.stringValue) else { alert("Name not saved", "Use 1–80 readable characters, without control or directional formatting characters.", for: current?.window); return }
    }
    @objc private func resetMicrophonePermission() { if let origin { clearMicrophoneConsent(origin) } }
    private func clearMicrophoneConsent(_ origin: URL) {
        microphoneConsent.reset(origin)
        for page in pages where page.view.workspaceOrigin == origin { page.view.setMicrophoneCaptureState(.none) }
    }
    @objc private func forgetStack() { if let origin { clearMicrophoneConsent(origin); store.remove(origin); persistWindows() } }
    private func welcome() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert(); dialog.messageText = "Welcome to FairyStack"
        dialog.informativeText = "Open your stack’s onboarding page in your browser and choose Open in FairyStack. It will appear in this Mac’s menu, ready to open whenever you need it."
        dialog.addButton(withTitle: "Open onboarding"); dialog.addButton(withTitle: "Try FairyStack")
        dialog.addButton(withTitle: "Add by address…"); dialog.addButton(withTitle: "Not now")
        switch dialog.runModal().rawValue {
        case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
            NSWorkspace.shared.open(URL(string: "https://fairystack.com/#existing-account")!); return nil
        case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
            trialSession = WorkspaceAddress.trialOrigin; return trialSession
        case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
            return askForAddress(current: nil)
        default: return nil
        }
    }
    private func askForAddress(current: URL?) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Add a stack by address"
        alert.informativeText = "Your stack’s onboarding page has Open in FairyStack: it adds the stack to this Mac’s menu. Enter an address here only for recovery."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); field.placeholderString = "https://you.fairystack.com"
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn else { return nil }
        guard let target = WorkspaceAddress.parse(field.stringValue), target.host != "fairystack.com", target.host != "www.fairystack.com" else {
            self.alert("That is not a FairyStack address", "Use the HTTPS origin of your stack, without a path.", for: nil); return nil
        }
        register(target); return target
    }
    private func persistWindows() {
        guard !restoring else { return }
        store.windows = pages.compactMap { page in
            guard let origin = page.view.workspaceOrigin, store.entries.contains(where: { $0.url == origin }) else { return nil }
            let url = page.view.url.flatMap { WorkspaceAddress.sameOrigin($0, origin) ? $0 : nil } ?? origin.appendingPathComponent("workspace/")
            return SavedStackWindow(origin: origin, url: url)
        }
    }

    @discardableResult
    private func open(_ request: URLRequest?, origin: URL, configuration: WKWebViewConfiguration?, activate: Bool = true, opener: WorkspaceWebView? = nil) -> WorkspaceWebView {
        let config = configuration ?? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = origin.host == WorkspaceAddress.trialOrigin.host ? .nonPersistent() : .default()
            config.userContentController = content
            config.applicationNameForUserAgent = "FairyStackMac/\(version)"
            config.preferences.isElementFullscreenEnabled = true
            return config
        }()
        // Popups keep WebKit's process pool and storage. Do not give approval sites
        // the image bridge; pairing has its own main-frame, origin and path gate.
        if opener != nil {
            let popupContent = WKUserContentController()
            popupContent.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: "fairystackPair")
            popupContent.addScriptMessageHandler(WeakReplyMessageHandler(self), contentWorld: .page, name: "fairystackConnect")
            config.userContentController = popupContent
        }
        let view = WorkspaceWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 860), configuration: config)
        view.workspaceOrigin = origin
        view.isAuxiliary = opener != nil; view.opener = opener
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.dragSource.failed = { [weak self, weak view] message in self?.alert("Image not saved", message, for: view?.window) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.title = "FairyStack · \(origin.host ?? "")"; window.contentView = view; window.delegate = self
        if pages.isEmpty { if !window.setFrameUsingName("FairyStackWorkspace") { window.center() }; window.setFrameAutosaveName("FairyStackWorkspace") }
        else if let last = pages.last?.window { window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY))) }
        let title = view.observe(\.title) { [weak window] view, _ in
            let host = view.isAuxiliary ? (view.url?.host ?? origin.host) : origin.host
            window?.title = "\((view.title ?? "").isEmpty ? "FairyStack" : view.title!) · \(host ?? "")"
        }
        if view.isAuxiliary { auxiliaries.append((window, view, title)) }
        else { pages.append((window, view, title)) }
        if let request { view.load(request) }
        if !restoring && !view.isAuxiliary { focusedView = view; store.select(origin); persistWindows() }
        store.defaults.set(true, forKey: Self.openKey)
        NSApp.setActivationPolicy(.regular)
        if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { window.orderFront(nil) }
        return view
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let view = window.contentView as? WorkspaceWebView { microphoneConsent.cancel(owner: view) }
        if let index = auxiliaries.firstIndex(where: { $0.window === window }) {
            let view = auxiliaries[index].view
            for child in auxiliaries.filter({ $0.view.opener === view }) { child.window.close() }
            view.stopLoading()
            auxiliaries.removeAll { $0.view === view }
            // Closing native chrome must update the opener's WindowProxy too.
            view.evaluateJavaScript("window.close()", completionHandler: nil)
            return
        }
        guard let index = pages.firstIndex(where: { $0.window === window }) else { return }
        if terminating { return }
        for child in auxiliaries.filter({ $0.view.opener === pages[index].view }) { child.window.close() }
        if focusedView === pages[index].view { focusedView = nil }
        pages[index].view.stopLoading(); pages.remove(at: index)
        persistWindows()
        if pages.isEmpty {
            if !terminating { store.defaults.set(false, forKey: Self.openKey) }
            if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func allowedInWindow(_ url: URL, view: WKWebView) -> Bool {
        guard let origin = (view as? WorkspaceWebView)?.workspaceOrigin else { return false }
        if WorkspaceAddress.sameOrigin(url, origin) { return true }
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        guard (url.port ?? 443) == 443 else { return false }
        if host == "authreturn.com" || host.hasSuffix(".authreturn.com") { return true }
        return (view as? WorkspaceWebView)?.isAuxiliary == true && host == "voice-feed.aisloppy.com"
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.dragMessage, let view = message.webView as? WorkspaceWebView,
              !view.isAuxiliary, let origin = view.workspaceOrigin, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == origin.host,
              (message.frameInfo.securityOrigin.port == (origin.port ?? 443) || (message.frameInfo.securityOrigin.port == 0 && origin.port == nil)) else { return }
        view.draggable = DraggableImage(message.body, origin: origin)
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                      replyHandler: @escaping (Any?, String?) -> Void) {
        if message.name == "fairystackDiagnostics" {
            guard let view = message.webView as? WorkspaceWebView, !view.isAuxiliary,
                  let origin = view.workspaceOrigin, let url = view.url,
                  message.frameInfo.isMainFrame, message.frameInfo.webView === view,
                  WorkspaceAddress.sameOrigin(url, origin),
                  WorkspaceAddress.sameOrigin(message.frameInfo.securityOrigin, origin),
                  let body = message.body as? [String: Any], let action = body["action"] as? String
            else { replyHandler(nil, "Diagnostics are only available to this stack’s main window."); return }
            diagnostics.saw(origin: origin)
            if action == "read", body.count == 1 {
                diagnostics.collectCrashes(origin: origin) { [weak self] in
                    guard let self else { replyHandler(nil, "Window closed."); return }
                    replyHandler(["events": self.diagnostics.snapshot(origin: origin)], nil)
                }
            } else if action == "ack", body.count == 2, let ids = body["ids"] as? [String], ids.count <= 100,
                      ids.allSatisfy({ UUID(uuidString: $0) != nil }) {
                diagnostics.acknowledge(ids, origin: origin); replyHandler(["state": "acknowledged"], nil)
            } else if action == "capture", body.count == 2, let active = body["active"] as? Bool {
                diagnostics.saw(origin: origin, microphoneActive: active); replyHandler(["state": "recorded"], nil)
            } else { replyHandler(nil, "Invalid diagnostic request."); }
            return
        }
        if message.name == "fairystackMicrophone" {
            guard let view = message.webView as? WorkspaceWebView, !view.isAuxiliary,
                  let origin = view.workspaceOrigin, let url = view.url,
                  message.frameInfo.isMainFrame, message.frameInfo.webView === view,
                  WorkspaceAddress.sameOrigin(url, origin),
                  WorkspaceAddress.sameOrigin(message.frameInfo.securityOrigin, origin),
                  let body = message.body as? [String: String], body == ["action": "claim"]
            else { replyHandler(nil, "Microphone ownership is only available to this saved stack’s main window."); return }
            microphone.claim(view) { error in
                if let error { replyHandler(nil, error) }
                else { replyHandler(["state": "owned"], nil) }
            }
            return
        }
        guard ["fairystackPair", "fairystackConnect"].contains(message.name), let view = message.webView as? WorkspaceWebView,
              let origin = view.workspaceOrigin, let window = view.window,
              message.frameInfo.isMainFrame, let frameURL = message.frameInfo.request.url,
              WorkspaceAddress.sameOrigin(frameURL, origin), frameURL.path == "/companions",
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == origin.host,
              (message.frameInfo.securityOrigin.port == (origin.port ?? 443) || (message.frameInfo.securityOrigin.port == 0 && origin.port == nil)),
              let token = LocalPairingRequest.token(message.body, frameURL: frameURL, origin: origin, mainFrame: message.frameInfo.isMainFrame),
              let connectLocal else { replyHandler(nil, "Local pairing is only available from this stack’s Connect window."); return }
        connectLocal(origin, token, window) { error in
            if let error { replyHandler(nil, error) }
            else { replyHandler(["state": "connecting"], nil) }
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload {
            guard let origin = (webView as? WorkspaceWebView)?.workspaceOrigin, WorkspaceAddress.sameOrigin(url, origin) else { return decisionHandler(.cancel) }
            return decisionHandler(.download)
        }
        let approvalPopup = action.targetFrame == nil && WorkspaceAddress.sameOrigin(url, URL(string: "https://voice-feed.aisloppy.com")!)
        if approvalPopup || action.targetFrame?.isMainFrame == false || ["about", "blob", "data"].contains(url.scheme ?? "") || allowedInWindow(url, view: webView) {
            return decisionHandler(.allow)
        }
        launchExternal(url); decisionHandler(.cancel)
    }
    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType {
            guard let url = response.response.url, let origin = (webView as? WorkspaceWebView)?.workspaceOrigin, WorkspaceAddress.sameOrigin(url, origin) else { return decisionHandler(.cancel) }
        }
        decisionHandler(disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType ? .download : .allow)
    }
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(webView, error) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(webView, error) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let view = webView as? WorkspaceWebView, !view.isAuxiliary, let origin = view.workspaceOrigin {
            diagnostics.webProcessTerminated(origin: origin, microphoneActive: webView.microphoneCaptureState != .none)
        }
        microphoneConsent.cancel(owner: webView)
        webView.reload()
    }

    private func loadFailed(_ webView: WKWebView, _ error: Error) {
        let error = error as NSError
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let retry = failedURL.flatMap { allowedInWindow($0, view: webView) ? $0 : nil } ?? (webView as? WorkspaceWebView)?.workspaceOrigin?.appendingPathComponent("workspace/")
        let escape = { (text: String) in text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>FairyStack is unreachable</title>
        <style>:root{color:#17211c;background:#edf7f1}a{color:#1f6b45;background:transparent}
        @media(prefers-color-scheme:dark){:root{color:#e6efe9;background:#141c18}a{color:#9fd8b4}}
        body{font:15px -apple-system,system-ui;margin:18vh auto;max-width:520px;padding:0 24px}</style>
        <h1>FairyStack could not load</h1><p>\(escape(error.localizedDescription))</p>
        <p><a href="\(escape(retry?.absoluteString ?? "about:blank"))">Retry</a> or press ⌘R.</p>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        guard let parent = webView as? WorkspaceWebView, let origin = parent.workspaceOrigin else { return nil }
        // window.open('about:blank') is a bootstrap, followed asynchronously by
        // the verified approval URL. Returning nil loses the live WindowProxy.
        let voiceApproval = WorkspaceAddress.sameOrigin(url, URL(string: "https://voice-feed.aisloppy.com")!)
        guard url.absoluteString == "about:blank" || allowedInWindow(url, view: parent) || voiceApproval else {
            launchExternal(url); return nil
        }
        return open(nil, origin: origin, configuration: configuration, opener: parent)
    }
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { microphoneConsent.cancel(owner: webView) }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { persistWindows() }
    public func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }
    // Microphone permission belongs only to this saved stack's main frame.
    // Camera, subframes, approval popups and navigated external pages stay denied.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor securityOrigin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // WebKit can supply a nil Objective-C request for capture frames despite
        // Swift importing WKFrameInfo.request as nonoptional. Even request.url
        // traps while bridging it. Permission uses the supplied security origins.
        guard type == .microphone, frame.isMainFrame, frame.webView === webView,
              let workspace = webView as? WorkspaceWebView, !workspace.isAuxiliary,
              let origin = workspace.workspaceOrigin, let url = webView.url,
              WorkspaceAddress.sameOrigin(url, origin),
              WorkspaceAddress.sameOrigin(securityOrigin, origin),
              WorkspaceAddress.sameOrigin(frame.securityOrigin, origin)
        else { decisionHandler(.deny); return }
        // Old pages may still request capture without the preflight bridge. They
        // can acquire an idle Mac, but must never mute another workspace.
        guard microphone.admitPermission(workspace) else { decisionHandler(.deny); return }
        microphoneConsent.request(owner: workspace, origin: origin, window: webView.window, valid: { [weak self, weak workspace] in
            guard let workspace, !workspace.isAuxiliary, workspace.workspaceOrigin == origin,
                  let current = workspace.url else { return false }
            return WorkspaceAddress.sameOrigin(current, origin) && self?.microphone.admitPermission(workspace) == true
        }, reply: decisionHandler)
    }

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
        guard let url = response.url, let origin = (download.webView as? WorkspaceWebView)?.workspaceOrigin,
              WorkspaceAddress.sameOrigin(url, origin) else { return completionHandler(nil) }
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
    public func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard let url = request.url, let origin = (download.webView as? WorkspaceWebView)?.workspaceOrigin,
              WorkspaceAddress.sameOrigin(url, origin) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
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

final class WeakReplyMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var target: WKScriptMessageHandlerWithReply?
    init(_ target: WKScriptMessageHandlerWithReply) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let target else { replyHandler(nil, "The Connect window closed."); return }
        target.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}
