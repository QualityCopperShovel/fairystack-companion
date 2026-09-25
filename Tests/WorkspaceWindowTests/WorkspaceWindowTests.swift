import AppKit
import WebKit
import XCTest
@testable import WorkspaceWindow

private let origin = URL(string: "https://you.fairystack.com")!
private func descriptor(_ changes: [String: Any] = [:]) -> [String: Any] {
    var body: [String: Any] = ["url": "https://you.fairystack.com/api/agent-console/sessions/s1/images/comic.png/download?expires=9&signature=ab",
                               "filename": "comic.png", "mime_type": "image/png",
                               "expires_at": Date().timeIntervalSince1970 + 600,
                               "rect": ["x": 0.0, "y": 0.0, "width": 200.0, "height": 200.0]]
    changes.forEach { body[$0.key] = $0.value }
    return body
}

final class AddressAndDescriptorTests: XCTestCase {
    func testAddressesAreHTTPSOriginsOnly() {
        XCTAssertEqual(WorkspaceAddress.parse(" You.FairyStack.com ")?.absoluteString, "https://you.fairystack.com")
        XCTAssertEqual(WorkspaceAddress.parse("https://you.fairystack.com/")?.absoluteString, "https://you.fairystack.com")
        for bad in ["http://you.fairystack.com", "https://you.fairystack.com/workspace", "https://a:b@you.fairystack.com", "https://x.com/?q=1", "localhost"] {
            XCTAssertNil(WorkspaceAddress.parse(bad), bad)
        }
    }
    func testTrialOriginIsAValidStackAddress() {
        XCTAssertEqual(WorkspaceAddress.parse(WorkspaceAddress.trialOrigin.absoluteString), WorkspaceAddress.trialOrigin)
    }
    func testOpenLinksCarryOnlyAStackOrigin() {
        XCTAssertEqual(WorkspaceAddress.fromOpenURL(URL(string: "fairystack://open?origin=https%3A%2F%2Fyou.fairystack.com")!)?.absoluteString, "https://you.fairystack.com")
        for bad in ["fairystack://open?origin=https://fairystack.com", "fairystack://open?origin=http://you.fairystack.com",
                    "fairystack://open?origin=https://you.fairystack.com/workspace", "fairystack://pair?origin=https://you.fairystack.com",
                    "https://open?origin=https://you.fairystack.com", "fairystack://open"] {
            XCTAssertNil(WorkspaceAddress.fromOpenURL(URL(string: bad)!), bad)
        }
    }
    func testDescriptorMustBeSameOriginSafeAndImage() {
        let image = DraggableImage(descriptor(), origin: origin)
        XCTAssertEqual(image?.filename, "comic.png"); XCTAssertEqual(image?.type, .png); XCTAssertEqual(image?.isFresh, true)
        XCTAssertNil(DraggableImage(descriptor(["url": "https://evil.test/comic.png"]), origin: origin))
        XCTAssertNil(DraggableImage(descriptor(["filename": "../comic.png"]), origin: origin))
        XCTAssertNil(DraggableImage(descriptor(["mime_type": "image/svg+xml"]), origin: origin))
        XCTAssertNil(DraggableImage(NSNull(), origin: origin))
        XCTAssertEqual(DraggableImage(descriptor(["expires_at": Date().timeIntervalSince1970 + 2]), origin: origin)?.isFresh, false)
    }
}

final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = Data("PNG-ORIGINAL".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FilePromiseTests: XCTestCase {
    private func write(status: Int) throws -> (URL, Error?, String?) {
        StubProtocol.status = status
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let source = ImageFileDragSource(configuration: config)
        var alert: String?
        source.failed = { alert = $0 }
        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: source)
        provider.userInfo = DraggableImage(descriptor(), origin: origin)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.filePromiseProvider(provider, fileNameForType: "public.png"))
        let done = expectation(description: "promise written"); var failure: Error?
        source.filePromiseProvider(provider, writePromiseTo: destination) { failure = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let shown = expectation(description: "main queue drained"); DispatchQueue.main.async { shown.fulfill() }; wait(for: [shown], timeout: 2)
        return (destination, failure, alert)
    }
    func testDropWritesTheSignedOriginalUnderItsName() throws {
        let (file, failure, alert) = try write(status: 200)
        XCTAssertNil(failure); XCTAssertNil(alert)
        XCTAssertEqual(file.lastPathComponent, "comic.png")
        XCTAssertEqual(try Data(contentsOf: file), StubProtocol.body)
    }
    func testExpiredLinkFailsVisiblyWithoutAFile() throws {
        let (file, failure, alert) = try write(status: 403)
        XCTAssertNotNil(failure); XCTAssertTrue(alert?.contains("HTTP 403") == true, alert ?? "no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

// Real WebKit hit-testing: the subclass must see mouse events before the page does.
final class MouseRoutingTests: XCTestCase, WKScriptMessageHandler {
    private var clicks = 0
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { clicks += 1 }

    private func makeView() -> (NSWindow, WorkspaceWebView) {
        let config = WKWebViewConfiguration(); config.userContentController.add(self, name: "clicked")
        let view = WorkspaceWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        let loaded = expectation(description: "page loaded"); let delegate = LoadWaiter { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString("<body style='margin:0'><div id=i style='width:200px;height:200px;background:#4a8'></div><script>document.addEventListener('click',()=>webkit.messageHandlers.clicked.postMessage(1))</script>", baseURL: origin)
        wait(for: [loaded], timeout: 15); _ = delegate
        return (window, view)
    }
    private func event(_ type: NSEvent.EventType, _ window: NSWindow, _ x: CGFloat, _ yFromTop: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.contentView!.bounds.height - yFromTop), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    private func send(_ event: NSEvent, _ window: NSWindow) {
        guard let view = window.contentView?.hitTest(event.locationInWindow) else { return XCTFail("no view at \(event.locationInWindow)") }
        switch event.type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
    private func settle(_ seconds: TimeInterval = 1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testPressAndMoveOnTheAnnouncedImageStartsANativeFileDrag() {
        let (window, view) = makeView()
        view.draggable = DraggableImage(descriptor(), origin: origin)
        var started: DraggableImage?
        view.startDrag = { _, image in started = image }
        XCTAssertTrue(window.contentView!.hitTest(NSPoint(x: 50, y: 250)) === view, "WebKit must deliver mouse events to the web view itself")
        send(event(.leftMouseDown, window, 50, 50), window)
        send(event(.leftMouseDragged, window, 70, 80), window)
        XCTAssertEqual(view.presses, 1); XCTAssertEqual(view.lastPressPoint, CGPoint(x: 50, y: 50), "CSS viewport point")
        XCTAssertEqual(started?.filename, "comic.png")
        send(event(.leftMouseUp, window, 70, 80), window); settle()
        XCTAssertEqual(clicks, 0, "a drag is not also a click")
        window.close()
    }
    func testPressAndReleaseIsReplayedAsAnOrdinaryClick() {
        let (window, view) = makeView()
        view.draggable = DraggableImage(descriptor(), origin: origin)
        var started = false; view.startDrag = { _, _ in started = true }
        send(event(.leftMouseDown, window, 50, 50), window)
        send(event(.leftMouseUp, window, 50, 50), window); settle()
        XCTAssertFalse(started); XCTAssertEqual(clicks, 1, "the page still receives the click that opens the viewer")
        window.close()
    }
    func testPressOutsideTheAnnouncedImageIsLeftToWebKit() {
        let (window, view) = makeView()
        view.draggable = DraggableImage(descriptor(), origin: origin)
        var started = false; view.startDrag = { _, _ in started = true }
        send(event(.leftMouseDown, window, 300, 250), window)
        send(event(.leftMouseDragged, window, 340, 280), window)
        send(event(.leftMouseUp, window, 340, 280), window); settle()
        XCTAssertFalse(started)
        window.close()
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}

final class FairyIconTests: XCTestCase {
    func testMenuBarFairyIsATemplateWithWingsOrbAndSparkles() throws {
        let icon = FairyIcon.menuBar()
        XCTAssertTrue(icon.isTemplate); XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72)); NSGraphicsContext.restoreGraphicsState()
        // Bitmap rows run top-down: orb at the bottom centre, wings above it, sparkles low on each side, clear corners.
        func ink(_ x: Double, _ yUp: Double) -> Bool { (rep.colorAt(x: Int(x * 4), y: Int((18 - yUp) * 4))?.alphaComponent ?? 0) > 0.5 }
        XCTAssertTrue(ink(9, 5), "orb"); XCTAssertTrue(ink(4.6, 13.6), "left wing"); XCTAssertTrue(ink(13.4, 13.6), "right wing")
        XCTAssertTrue(ink(1.9, 4.2), "left sparkle"); XCTAssertTrue(ink(16.1, 4.2), "right sparkle")
        XCTAssertFalse(ink(0.5, 17.5)); XCTAssertFalse(ink(9, 9.6), "gap between orb and wings")
        if let folder = ProcessInfo.processInfo.environment["ICON_PREVIEW_DIR"] {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("menubar-fairy@4x.png"))
        }
    }
}

final class SavedStackTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let second = URL(string: "https://other.fairystack.com")!
    override func setUp() {
        suite = "FairyStackTests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
        _ = NSApplication.shared
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    func testMigrationDeduplicationSelectionAndRelaunch() {
        defaults.set("https://YOU.fairystack.com:443/", forKey: WorkspaceAddress.defaultsKey)
        let store = SavedStacks(defaults: defaults)
        XCTAssertEqual(store.entries.map(\.url), [origin])
        XCTAssertNil(defaults.string(forKey: WorkspaceAddress.defaultsKey))
        store.add(second); store.add(origin); store.add(WorkspaceAddress.parse("https://you.fairystack.com:443")!)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertTrue(store.rename(second, to: "Work")); store.select(second)
        let reopened = SavedStacks(defaults: defaults)
        XCTAssertEqual(reopened.entries, store.entries); XCTAssertEqual(reopened.selected, second)
        XCTAssertFalse(reopened.rename(second, to: "bad\u{202E}name"))
        XCTAssertFalse(reopened.rename(second, to: "\n"))
    }
    func testPairingFallbackAndTrialAreNotAnAccountDirectory() {
        let store = SavedStacks(defaults: defaults)
        store.migrate(pairedOrigin: origin); XCTAssertEqual(store.entries.map(\.url), [origin])
        store.add(second); store.migrate(pairedOrigin: URL(string: "https://unknown.fairystack.com")!)
        XCTAssertEqual(store.entries.count, 2)
        store.remove(origin); store.remove(second)
        SavedStacks(defaults: defaults).migrate(pairedOrigin: origin)
        XCTAssertTrue(SavedStacks(defaults: defaults).entries.isEmpty, "forget must survive pairing fallback")
        defaults.set(WorkspaceAddress.trialOrigin.absoluteString, forKey: WorkspaceAddress.defaultsKey)
        let trial = SavedStacks(defaults: defaults); trial.add(WorkspaceAddress.trialOrigin)
        trial.windows = [SavedStackWindow(origin: WorkspaceAddress.trialOrigin, url: WorkspaceAddress.trialOrigin)]
        XCTAssertTrue(trial.entries.isEmpty); XCTAssertTrue(trial.windows.isEmpty)
        XCTAssertNil(defaults.string(forKey: WorkspaceAddress.defaultsKey))
    }
    func testDuplicateAndMalformedHandoffsNeverResolve() {
        for query in ["origin=https://you.fairystack.com&origin=https://other.fairystack.com", "origin=https://you.fairystack.com&name=Trusted", "origin=https://you.fairystack.com&token=secret"] {
            XCTAssertNil(WorkspaceAddress.fromOpenURL(URL(string: "fairystack://open?" + query)!))
        }
        for text in ["fairystack://open/path?origin=https://you.fairystack.com", "fairystack://user@open?origin=https://you.fairystack.com", "fairystack://open?origin=https://you.fairystack.com#bad"] {
            XCTAssertNil(WorkspaceAddress.fromOpenURL(URL(string: text)!))
        }
    }
    func testMultipleWindowsKeepTheirOriginsAndRestoreTogether() {
        let store = SavedStacks(defaults: defaults); store.add(origin); store.add(second)
        let windows = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        let a = windows.openStack(origin, activate: false), b = windows.openStack(second, activate: false)
        a.stopLoading(); b.stopLoading()
        XCTAssertFalse(a === b)
        XCTAssertTrue(windows.openStack(origin, activate: false) === a, "switch focuses without navigating or discarding drafts")
        let another = windows.openStack(origin, newWindow: true, activate: false); another.stopLoading()
        XCTAssertFalse(another === a); XCTAssertEqual(another.workspaceOrigin, origin)
        XCTAssertTrue(windows.allowedInWindow(origin, view: a)); XCTAssertFalse(windows.allowedInWindow(second, view: a))
        XCTAssertTrue(windows.allowedInWindow(second, view: b)); XCTAssertFalse(windows.allowedInWindow(origin, view: b))
        XCTAssertNotNil(DraggableImage(descriptor(), origin: a.workspaceOrigin!))
        XCTAssertNil(DraggableImage(descriptor(), origin: b.workspaceOrigin!))
        XCTAssertTrue(a.window!.title.contains("you.fairystack.com")); XCTAssertTrue(b.window!.title.contains("other.fairystack.com"))
        let trial = windows.openStack(WorkspaceAddress.trialOrigin, newWindow: true, activate: false); trial.stopLoading()
        XCTAssertFalse(trial.configuration.websiteDataStore.isPersistent)
        windows.terminating = true
        let records = SavedStacks(defaults: defaults).windows
        XCTAssertEqual(records.map(\.origin), [origin, second, origin], "trial never restores")
        for view in [a, b, another, trial] { view.window?.close() }
        let next = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        next.adopt([]); next.restore()
        XCTAssertEqual(SavedStacks(defaults: defaults).windows.map(\.origin), records.map(\.origin))
        let reopenedA = next.openStack(origin, activate: false), reopenedB = next.openStack(second, activate: false)
        XCTAssertEqual(reopenedA.workspaceOrigin, origin); XCTAssertEqual(reopenedB.workspaceOrigin, second)
        XCTAssertEqual(SavedStacks(defaults: defaults).windows.count, 3)
        // Closing one window removes only its record. Quit keeps the remaining records intact.
        reopenedB.window?.close(); XCTAssertEqual(SavedStacks(defaults: defaults).windows.count, 2)
        next.terminating = true
        for window in NSApp.windows where window.contentView is WorkspaceWebView { window.close() }
    }
    func testSwitchingStacksPreservesTheLiveDraftAndSelection() {
        let store = SavedStacks(defaults: defaults); store.add(origin); store.add(second)
        let manager = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        let a = manager.openStack(origin, activate: false); a.stopLoading()
        let loaded = expectation(description: "draft fixture loaded")
        let delegate = LoadWaiter { loaded.fulfill() }; a.navigationDelegate = delegate
        a.loadHTMLString("<textarea id='draft'>My unsent draft</textarea><p id='evidence' tabindex='0'>Selected evidence</p>", baseURL: origin)
        wait(for: [loaded], timeout: 15); a.navigationDelegate = manager
        func evaluate(_ script: String) -> [String]? {
            let checked = expectation(description: "read WebKit state")
            var state: [String]?
            a.evaluateJavaScript(script) { result, error in
                XCTAssertNil(error); state = result as? [String]; checked.fulfill()
            }
            wait(for: [checked], timeout: 10); return state
        }
        // WebKit has one DOM range. Clear it before adding our range, and assert
        // the fixture really selected text before exercising the stack switch.
        let selected = ["My unsent draft", "Selected evidence", "evidence"]
        XCTAssertEqual(evaluate("evidence.focus(); const range=document.createRange(); range.selectNodeContents(evidence); getSelection().removeAllRanges(); getSelection().addRange(range); [draft.value, String(getSelection()), document.activeElement.id]"), selected)
        let b = manager.openStack(second, activate: false); b.stopLoading()
        XCTAssertTrue(manager.openStack(origin, activate: false) === a)
        XCTAssertEqual(evaluate("[draft.value, String(getSelection()), document.activeElement.id]"), selected)
        // Input focus/caret and rendered-text selection are separate browser states.
        let focused = ["My unsent draft", "draft", "3", "6"]
        XCTAssertEqual(evaluate("draft.focus(); draft.setSelectionRange(3,6); [draft.value, document.activeElement.id, String(draft.selectionStart), String(draft.selectionEnd)]"), focused)
        XCTAssertTrue(manager.openStack(second, activate: false) === b)
        XCTAssertTrue(manager.openStack(origin, activate: false) === a)
        XCTAssertEqual(evaluate("[draft.value, document.activeElement.id, String(draft.selectionStart), String(draft.selectionEnd)]"), focused)
        a.window?.close(); b.window?.close()
    }
    func testMenuListsStacksDirectlyAndEachHasANewWindowAction() {
        let store = SavedStacks(defaults: defaults); store.add(origin); store.add(second)
        let manager = WorkspaceWindows(version: "test", pairedOrigin: { origin }, defaults: defaults)
        let menu = NSMenu(), anchor = NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
        menu.addItem(anchor); manager.installStackMenu(in: menu, before: anchor); manager.menuNeedsUpdate(menu)
        let rows = menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(rows.map(\.title), ["you.fairystack.com", "other.fairystack.com"])
        XCTAssertEqual(rows.map(\.state), [.off, .on])
        let newWindows = menu.items.first { $0.title == "Open in New Window" }!.submenu!
        XCTAssertEqual(newWindows.items.count, 2)
        XCTAssertTrue(menu.items.contains { $0.title == "Mac commands · https://you.fairystack.com" })
        manager.menuNeedsUpdate(menu); XCTAssertEqual(menu.items.filter { $0.representedObject is String }.count, 2)
    }
    func testRestorationRejectsOtherOriginsAndForgottenStacks() {
        let store = SavedStacks(defaults: defaults); store.add(origin)
        store.windows = [SavedStackWindow(origin: origin, url: second), SavedStackWindow(origin: second, url: second), SavedStackWindow(origin: origin, url: origin)]
        XCTAssertEqual(store.windows.count, 1)
        store.remove(origin); XCTAssertTrue(store.windows.isEmpty)
    }
}

// Exercises WebKit's actual WindowProxy bootstrap and delayed navigation. No live
// account is mutated: the probe records the production policy, then cancels I/O.
private final class PopupPolicyProbe: NSObject, WKNavigationDelegate {
    let windows: WorkspaceWindows
    var decisions: [(URL, WKNavigationActionPolicy)] = []
    init(_ windows: WorkspaceWindows) { self.windows = windows }
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        windows.webView(view, decidePolicyFor: action) { policy in
            if let url = action.request.url { self.decisions.append((url, policy)) }
            decisionHandler(.cancel)
        }
    }
}

final class ApprovalPopupTests: XCTestCase {
    private func spin(_ ready: () -> Bool, timeout: TimeInterval = 8) {
        let end = Date().addingTimeInterval(timeout)
        while !ready() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(ready(), "WebKit operation reached its deadline")
    }
    @discardableResult
    private func js(_ view: WKWebView, _ source: String) -> Any? {
        var done = false, result: Any?
        view.evaluateJavaScript(source) { value, error in
            XCTAssertNil(error); result = value; done = true
        }
        spin({ done }); return result
    }
    func testBlankBootstrapDelayedApprovalExternalSafetyAndClose() throws {
        _ = NSApplication.shared
        let suite = "FairyStackPopupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let second = URL(string: "https://other.fairystack.com")!
        let store = SavedStacks(defaults: defaults); store.add(origin); store.add(second)
        let windows = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        var launched: [URL] = []; windows.openExternal = { launched.append($0) }
        let parent = windows.openStack(origin, activate: false)
        let other = windows.openStack(second, activate: false)
        parent.stopLoading(); other.stopLoading()
        parent.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let loaded = expectation(description: "opener fixture loaded")
        let waiter = LoadWaiter { loaded.fulfill() }; parent.navigationDelegate = waiter
        parent.loadHTMLString("<title>Composer fixture</title><textarea>keep draft</textarea>", baseURL: origin)
        wait(for: [loaded], timeout: 15); parent.navigationDelegate = windows
        defer { parent.window?.close(); other.window?.close() }
        XCTAssertEqual(js(parent, "window.approval = window.open('about:blank', 'voice-feed-connect', 'popup,width=540,height=760'); !!approval && !approval.closed") as? Bool, true)
        var popup: WorkspaceWebView?
        spin({
            popup = NSApp.windows.compactMap { $0.contentView as? WorkspaceWebView }.first { $0.opener === parent }
            return popup != nil
        })
        let approval = try XCTUnwrap(popup)
        XCTAssertTrue(approval.isAuxiliary); XCTAssertEqual(approval.workspaceOrigin, origin)
        XCTAssertEqual(windows.origin, second, "popup never switches the focused saved stack")
        XCTAssertEqual(SavedStacks(defaults: defaults).windows.map(\.origin), [origin, second], "approval never restores as a workspace")
        XCTAssertTrue(launched.isEmpty, "about:blank must not reach LaunchServices")
        let probe = PopupPolicyProbe(windows); approval.navigationDelegate = probe
        js(parent, "setTimeout(() => { approval.location = 'https://voice-feed.aisloppy.com/?connect=fixture'; }, 100); void 0")
        spin({ probe.decisions.contains { $0.0.host == "voice-feed.aisloppy.com" } })
        XCTAssertEqual(probe.decisions.last?.1, .allow)
        XCTAssertEqual(js(parent, "!approval.closed") as? Bool, true, "approval stays alive while status polling runs")
        XCTAssertFalse(windows.allowedInWindow(URL(string: "https://voice-feed.aisloppy.com/")!, view: parent))
        XCTAssertTrue(windows.allowedInWindow(URL(string: "https://authreturn.com/login")!, view: approval))
        for bad in ["https://voice-feed.aisloppy.com.evil.test/", "https://voice-feed.aisloppy.com:444/", "https://user@voice-feed.aisloppy.com/", second.absoluteString] {
            XCTAssertFalse(windows.allowedInWindow(URL(string: bad)!, view: approval), bad)
        }
        js(parent, "approval.location = 'https://external.example/'; void 0")
        spin({ launched.count == 1 })
        XCTAssertEqual(launched.first?.host, "external.example")
        XCTAssertEqual(probe.decisions.last?.1, .cancel)
        XCTAssertEqual(js(parent, "!approval.closed && document.querySelector('textarea').value === 'keep draft'") as? Bool, true)
        js(parent, "approval.close(); void 0")
        spin({ approval.window == nil || approval.window?.isVisible == false })
        XCTAssertEqual(js(parent, "approval.closed") as? Bool, true)
        XCTAssertEqual(SavedStacks(defaults: defaults).windows.count, 2)
        XCTAssertTrue(launched.allSatisfy { $0.scheme == "https" })
        // Native close-button cancellation also sets .closed for the polling owner.
        js(parent, "window.approval = window.open('about:blank', 'voice-feed-connect', 'popup'); void 0")
        var retry: WorkspaceWebView?
        spin({
            retry = NSApp.windows.compactMap { $0.contentView as? WorkspaceWebView }.first { $0.opener === parent && $0.window?.isVisible == true }
            return retry != nil
        })
        retry?.window?.close()
        spin({ self.js(parent, "approval.closed") as? Bool == true })
    }
}

final class LocalPairingRequestTests: XCTestCase {
    func testOnlyTheOwnedConnectPageCanRequestPairing() {
        let token = "fs_mac_" + String(repeating: "a", count: 43)
        let page = origin.appendingPathComponent("companions")
        XCTAssertEqual(LocalPairingRequest.token(["token":token], frameURL:page, origin:origin, mainFrame:true), token)
        XCTAssertNil(LocalPairingRequest.token(["token":token], frameURL:page, origin:origin, mainFrame:false))
        for url in [origin, URL(string:"https://evil.test/companions")!, URL(string:"http://you.fairystack.com/companions")!, URL(string:"https://you.fairystack.com:444/companions")!] {
            XCTAssertNil(LocalPairingRequest.token(["token":token], frameURL:url, origin:origin, mainFrame:true))
        }
        for body in [["token":"bad"], ["token":token,"origin":"https://evil.test"], ["token":1], NSNull()] as [Any] {
            XCTAssertNil(LocalPairingRequest.token(body, frameURL:page, origin:origin, mainFrame:true))
        }
    }
}


extension ApprovalPopupTests {
    func testPopupKeepsPairingBridgeButCannotPairFromBlankOrExternalPages() throws {
        _ = NSApplication.shared
        let suite = "FairyStackPairingPopupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        var requests = 0
        windows.connectLocal = { _, _, _, done in requests += 1; done(nil) }
        let parent = windows.openStack(origin, activate: false); parent.stopLoading()
        parent.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let loaded = expectation(description: "Connect opener loaded")
        let waiter = LoadWaiter { loaded.fulfill() }; parent.navigationDelegate = waiter
        parent.loadHTMLString("<title>Pairing opener</title>", baseURL: origin)
        wait(for: [loaded], timeout: 15); parent.navigationDelegate = windows
        defer { parent.window?.close() }
        js(parent, "window.connectPopup = window.open('about:blank', 'connect'); void 0")
        var popup: WorkspaceWebView?
        spin({ popup = NSApp.windows.compactMap { $0.contentView as? WorkspaceWebView }.first { $0.opener === parent }; return popup != nil })
        let connect = try XCTUnwrap(popup); defer { connect.window?.close() }
        XCTAssertEqual(js(connect, "typeof webkit.messageHandlers.fairystackPair.postMessage") as? String, "function")
        XCTAssertEqual(js(connect, "typeof webkit.messageHandlers.fairystackDrag") as? String, "undefined")
        js(connect, "window.pairingResult='pending'; webkit.messageHandlers.fairystackPair.postMessage({token:'fs_mac_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}).then(()=>window.pairingResult='allowed',()=>window.pairingResult='denied'); void 0")
        spin({ self.js(connect, "window.pairingResult") as? String == "denied" })
        XCTAssertEqual(requests, 0, "A popup cannot pair until its document is the owned Connect page")
    }
}
