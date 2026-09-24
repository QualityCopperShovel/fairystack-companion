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
