import AppKit
import WebKit
import XCTest
import WebKitPermissionFixtures
@testable import WorkspaceWindow

private let stack = URL(string: "https://capture.fairystack.com/")!

private final class CaptureLoadWaiter: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error; finished = true
    }
}

// The regressed expression is intentionally confined to a disposable subprocess.
private final class LegacyCaptureDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard frame.isMainFrame, let workspace = webView as? WorkspaceWebView,
              let saved = workspace.workspaceOrigin, let page = webView.url,
              let frameURL = frame.request.url,
              type == .microphone, WorkspaceAddress.sameOrigin(page, saved), WorkspaceAddress.sameOrigin(frameURL, saved)
        else { decisionHandler(.deny); return }
        decisionHandler(.prompt)
    }
}

final class MediaPermissionBoundaryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var windows: WorkspaceWindows!
    override func setUp() {
        _ = NSApplication.shared
        suite = "FairyStackCaptureTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        windows = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func spin(_ ready: () -> Bool, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(ready(), "capture fixture reached its bounded deadline")
    }
    private func view(page: URL = stack) -> WorkspaceWebView {
        let view = WorkspaceWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.workspaceOrigin = stack
        let waiter = CaptureLoadWaiter(); view.navigationDelegate = waiter
        view.loadHTMLString("<title>Permission boundary</title>", baseURL: page)
        spin { waiter.finished }; XCTAssertNil(waiter.error)
        XCTAssertEqual(view.url, page)
        return view
    }
    private func check(_ view: WKWebView, _ frame: WKFrameInfo, _ origin: WKSecurityOrigin,
                       _ expected: WKPermissionDecision, type: WKMediaCaptureType = .microphone,
                       file: StaticString = #filePath, line: UInt = #line) {
        var decisions: [WKPermissionDecision] = []
        FSRequestPermission(windows, view, origin, frame, type) { decisions.append($0) }
        XCTAssertEqual(decisions, [expected], "one synchronous terminal decision", file: file, line: line)
        XCTAssertEqual(FSRequestReads(frame), 0, "must never bridge a capture frame request", file: file, line: line)
    }
    func testNilRequestCrossesTheObjectiveCDelegateThunkWithoutReadingRequest() {
        let view = view(), origin = FSOrigin("https", "capture.fairystack.com", 0)
        let frame = FSNilRequestFrame(true, origin, view)
        check(view, frame, origin, .prompt)
        check(view, frame, FSOrigin("https", "CAPTURE.FAIRYSTACK.COM", 443), .prompt)
        for type in [WKMediaCaptureType.camera, .cameraAndMicrophone] { check(view, frame, origin, .deny, type: type) }
        for bad in [FSOrigin("http", "capture.fairystack.com", 0), FSOrigin("https", "evil.test", 443),
                    FSOrigin("https", "capture.fairystack.com", 444), FSOrigin("", "", 0)] {
            check(view, frame, bad, .deny)
            check(view, FSNilRequestFrame(true, bad, view), origin, .deny)
        }
        check(view, FSNilRequestFrame(false, origin, view), origin, .deny)
        check(view, FSNilRequestFrame(true, origin, nil), origin, .deny)
        let other = self.view()
        check(view, FSNilRequestFrame(true, origin, other), origin, .deny)
        view.isAuxiliary = true; check(view, frame, origin, .deny)
        view.isAuxiliary = false; view.workspaceOrigin = nil; check(view, frame, origin, .deny)
        let plain = WKWebView(); check(plain, FSNilRequestFrame(true, origin, plain), origin, .deny)
    }
    func testLivePageAndSavedOriginMustAgreeIncludingNonDefaultPorts() {
        let origin = FSOrigin("https", "capture.fairystack.com", 0)
        for page in [URL(string: "https://evil.test/")!, URL(string: "https://capture.fairystack.com:444/")!, URL(string: "http://capture.fairystack.com/")!] {
            let view = view(page: page)
            check(view, FSNilRequestFrame(true, origin, view), origin, .deny)
        }
        let view = view(page: URL(string: "https://capture.fairystack.com:8443/")!)
        view.workspaceOrigin = URL(string: "https://capture.fairystack.com:8443/")!
        let custom = FSOrigin("https", "capture.fairystack.com", 8443)
        check(view, FSNilRequestFrame(true, custom, view), custom, .prompt)
        check(view, FSNilRequestFrame(true, origin, view), custom, .deny)
        check(view, FSNilRequestFrame(true, custom, view), origin, .deny)
        let unloaded = WorkspaceWebView(); unloaded.workspaceOrigin = stack
        check(unloaded, FSNilRequestFrame(true, origin, unloaded), origin, .deny)
    }
    func testLegacyRequestBridgeCrashesOnlyInChild() throws {
        if ProcessInfo.processInfo.environment["FAIRYSTACK_LEGACY_CAPTURE_CRASH"] == "1" {
            let view = view(), origin = FSOrigin("https", "capture.fairystack.com", 0)
            FSRequestPermission(LegacyCaptureDelegate(), view, origin, FSNilRequestFrame(true, origin, view), .microphone) { _ in
                XCTFail("legacy nil request unexpectedly survived")
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "WorkspaceWindowTests.MediaPermissionBoundaryTests/testLegacyRequestBridgeCrashesOnlyInChild", Bundle(for: MediaPermissionBoundaryTests.self).bundleURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["FAIRYSTACK_LEGACY_CAPTURE_CRASH": "1"]) { _, new in new }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        process.standardOutput = output; process.standardError = output
        try process.run()
        spin({ !process.isRunning }, timeout: 30)
        if process.isRunning { process.terminate(); return }
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertTrue([SIGTRAP, SIGILL].contains(process.terminationStatus), "expected Foundation bridge trap, got \(process.terminationStatus)")
        print("Legacy nil NSURLRequest reproducer: isolated signal \(process.terminationStatus)")
    }
}

// This receives a genuine getUserMedia callback from a WebKit content process,
// forwards it through the production delegate, then simulates consent/denial.
// Only mocked devices may be granted. Production still returns .prompt, never .grant.
private final class CaptureProbe: NSObject, WKUIDelegate, WKScriptMessageHandler {
    let windows: WorkspaceWindows
    let acceptMock: Bool
    var decisions: [WKPermissionDecision] = []
    var frames: [Bool] = []
    var result: String?
    init(_ windows: WorkspaceWindows, acceptMock: Bool) { self.windows = windows; self.acceptMock = acceptMock }
    func webView(_ view: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        FSRequestPermission(windows, view, origin, frame, type) { decision in
            self.decisions.append(decision); self.frames.append(frame.isMainFrame)
            decisionHandler(decision == .prompt && self.acceptMock ? .grant : .deny)
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        result = message.body as? String
    }
}

final class MediaCaptureWebKitTests: XCTestCase {
    private func capture(constraints: String = "{audio:true}", subframe: Bool = false,
                         popup: Bool = false, acceptMock: Bool = false, mock: Bool = true) throws -> CaptureProbe {
        _ = NSApplication.shared
        let suite = "FairyStackRealCaptureTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        let probe = CaptureProbe(windows, acceptMock: acceptMock)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        if mock && !FSConfigureMockCapture(config.preferences) {
            throw NSError(domain: "CaptureFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit mock capture SPI unavailable; never grant a real device in a mock test"])
        }
        config.userContentController.add(probe, name: "capture")
        let view = WorkspaceWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        view.workspaceOrigin = stack; view.isAuxiliary = popup; view.uiDelegate = probe
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "capture"); window.close() }
        let script = """
        <script>
        let settled=false;
        function finish(value) { if(!settled) { settled=true; webkit.messageHandlers.capture.postMessage(value); } }
        setTimeout(()=>finish('TimedOut: getUserMedia did not settle'), 10000);
        navigator.mediaDevices.getUserMedia(\(constraints)).then(stream=>{
            const tracks=stream.getTracks(); const live=tracks.length>0 && tracks.every(t=>t.readyState==='live');
            tracks.forEach(t=>t.stop()); finish(live && tracks.every(t=>t.readyState==='ended') ? 'mock-capture-stopped' : 'invalid-tracks');
        }).catch(error=>finish(error.name));
        </script>
        """
        let html = subframe ? "<iframe allow='microphone; camera' srcdoc=\"\(script.replacingOccurrences(of: "\"", with: "&quot;"))\"></iframe>" : script
        view.loadHTMLString(html, baseURL: stack)
        let deadline = Date().addingTimeInterval(15)
        while probe.result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNotNil(probe.result, "WebKit capture reached the overall deadline")
        XCTAssertFalse(probe.result?.hasPrefix("TimedOut") ?? true, probe.result ?? "no result")
        print("WebKit capture mock=\(mock) subframe=\(subframe) popup=\(popup): decisions=\(probe.decisions.map(\.rawValue)) result=\(probe.result ?? "missing")")
        return probe
    }
    func testRealMicrophoneCallbackPromptsThenUserDenialTerminates() throws {
        let probe = try capture()
        XCTAssertEqual(probe.decisions, [.prompt]); XCTAssertEqual(probe.frames, [true])
        XCTAssertEqual(probe.result, "NotAllowedError")
    }
    func testRealMicrophoneCallbackCanStartAndStopMockAudioAfterConsent() throws {
        let probe = try capture(acceptMock: true)
        XCTAssertEqual(probe.decisions, [.prompt]); XCTAssertEqual(probe.result, "mock-capture-stopped")
    }
    func testRealSubframeCameraAndPopupAreDenied() throws {
        for probe in [try capture(subframe: true), try capture(popup: true), try capture(constraints: "{video:true}"), try capture(constraints: "{audio:true,video:true}")] {
            XCTAssertEqual(probe.decisions, [.deny]); XCTAssertEqual(probe.result, "NotAllowedError")
        }
    }
    func testNoHardwareCaptureTerminatesWithoutAnUnattendedPrompt() throws {
        let probe = try capture(mock: false)
        // Hosted machines may have no input device, so WebKit can reject before
        // consulting the delegate. Neither outcome is physical-capture evidence.
        XCTAssertTrue(["NotFoundError", "NotAllowedError", "NotReadableError"].contains(probe.result ?? ""))
        XCTAssertTrue(probe.decisions.isEmpty || probe.decisions == [.prompt])
    }
}

// Real WebKit content/GPU processes, mock devices only: no physical audio is
// captured or uploaded by CI. The two origins model Finance and Jessald.
private final class OwnershipCaptureProbe: NSObject, WKUIDelegate {
    let windows: WorkspaceWindows
    var legacy = true
    init(_ windows: WorkspaceWindows) { self.windows = windows }
    func webView(_ view: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        if legacy { decisionHandler(.grant); return } // Only FSConfigureMockCapture views.
        FSRequestPermission(windows, view, origin, frame, type) {
            decisionHandler($0 == .prompt ? .grant : .deny)
        }
    }
}

final class CrossOriginMicrophoneTests: XCTestCase {
    func testFinanceAndJessaldTransferStopsOldCaptureBeforeStartingNewCapture() throws {
        _ = NSApplication.shared
        let suite = "FairyStackOwnership." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = WorkspaceWindows(version: "test", pairedOrigin: { nil }, defaults: defaults)
        let probe = OwnershipCaptureProbe(windows)
        let data = WKWebsiteDataStore.nonPersistent()
        var views: [WorkspaceWebView] = [], nativeWindows: [NSWindow] = []
        func spin(_ ready: () -> Bool, seconds: Double = 15) {
            let end = Date().addingTimeInterval(seconds)
            while !ready() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertTrue(ready(), "Cross-origin capture exceeded its deadline")
        }
        func js(_ view: WKWebView, _ script: String) -> Any? {
            var finished = false, value: Any?, failure: Error?
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result { case .success(let result): value = result; case .failure(let error): failure = error }
                finished = true
            }
            spin { finished }; XCTAssertNil(failure)
            return value
        }
        defer {
            for view in views { _ = js(view, "await window.VoiceFeedClient.releaseForNativeTransfer(); return true;") }
            nativeWindows.forEach { $0.close() }
        }
        for host in ["finance-capture.fairystack.com", "jessald-capture.fairystack.com"] {
            let config = WKWebViewConfiguration(); config.websiteDataStore = data
            guard FSConfigureMockCapture(config.preferences) else { throw NSError(domain: "CaptureFixture", code: 1) }
            let view = WorkspaceWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
            view.workspaceOrigin = URL(string: "https://\(host)/")!; view.uiDelegate = probe
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
            views.append(view); nativeWindows.append(window)
            let waiter = CaptureLoadWaiter(); view.navigationDelegate = waiter
            view.loadHTMLString("<title>Cross-origin microphone fixture</title>", baseURL: view.workspaceOrigin)
            spin { waiter.finished }; XCTAssertNil(waiter.error)
            _ = js(view, """
                window.begin = async () => {
                    window.audio = new AudioContext(); await audio.resume();
                    window.stream = await navigator.mediaDevices.getUserMedia({audio:true});
                    window.track = stream.getAudioTracks()[0]; window.mutedEvents = 0;
                    track.onmute = () => { mutedEvents++; };
                    window.analyser = audio.createAnalyser(); audio.createMediaStreamSource(stream).connect(analyser);
                    window.recorder = new MediaRecorder(stream);
                    window.chunks = 0; recorder.ondataavailable = e => { if (e.data.size) chunks++; };
                    recorder.start(250); return track.readyState;
                };
                window.VoiceFeedClient = {releaseForNativeTransfer: async () => {
                    if (!window.stream) return;
                    if (recorder.state !== 'inactive') await new Promise(resolve => {recorder.onstop=resolve;recorder.stop();});
                    stream.getTracks().forEach(t => t.stop()); await audio.close();
                }};
                return true;
                """)
        }
        let finance = views[0], jessald = views[1]
        XCTAssertEqual(js(finance, "return await begin();") as? String, "live")
        XCTAssertEqual(js(jessald, "return await begin();") as? String, "live")
        let baselineMuted = js(finance, "await new Promise(r=>setTimeout(r,500)); return track.muted || mutedEvents > 0;") as? Bool
        print("Cross-origin legacy WebKit capture: Finance muted after Jessald starts = \(String(describing: baselineMuted))")
        XCTAssertEqual(baselineMuted, true, "Expected the actual dual-WKWebView contention seen in the operator's Mac logs")
        for view in views { _ = js(view, "await VoiceFeedClient.releaseForNativeTransfer(); return true;") }
        probe.legacy = false
        var claimed = false
        windows.microphone.claim(finance) { XCTAssertNil($0); claimed = true }
        spin { claimed }
        XCTAssertEqual(js(finance, "return await begin();") as? String, "live")
        claimed = false
        windows.microphone.claim(jessald) { XCTAssertNil($0); claimed = true }
        spin { claimed }
        XCTAssertEqual(js(finance, "return track.readyState + ':' + audio.state;") as? String, "ended:closed")
        XCTAssertTrue(windows.microphone.owner === jessald)
        XCTAssertEqual(js(jessald, "return await begin();") as? String, "live")
        let stable = js(jessald, """
            const before=audio.currentTime; await new Promise(r=>setTimeout(r,6000));
            return track.readyState==='live' && !track.muted && mutedEvents===0 && audio.currentTime>before && chunks>0;
            """) as? Bool
        XCTAssertEqual(stable, true, "Winning window must still receive audio after the old five-second recovery interval")
        print("Cross-origin coordinated capture: Finance ended/closed before Jessald begins; Jessald audio live beyond six seconds = \(String(describing: stable))")
        var updateReady: Bool?
        windows.canRestartForUpdate { updateReady = $0 }
        spin { updateReady != nil }
        XCTAssertEqual(updateReady, false, "A downloaded update cannot restart the recording window")
        // Lost old window / never-resolving drain cannot grant a second owner.
        _ = js(jessald, "window.savedRelease=VoiceFeedClient.releaseForNativeTransfer; VoiceFeedClient.releaseForNativeTransfer=()=>new Promise(()=>{}); return true;")
        windows.microphone.deadline = 0.05
        var terminal = false
        windows.microphone.claim(finance) { error in XCTAssertTrue(error?.contains("timed out") == true); terminal = true }
        spin { terminal }
        XCTAssertTrue(windows.microphone.owner === jessald)
        XCTAssertFalse(windows.microphone.admitPermission(finance))
        _ = js(jessald, "VoiceFeedClient.releaseForNativeTransfer=savedRelease; return true;")
        _ = js(jessald, "await VoiceFeedClient.releaseForNativeTransfer(); return true;")
        var captureStopped = false
        jessald.setMicrophoneCaptureState(.none) { captureStopped = true }
        spin { captureStopped }
        _ = js(jessald, "window.FairyStackReloadGuard={busy:()=>true}; return true;")
        updateReady = nil
        windows.canRestartForUpdate { updateReady = $0 }
        spin { updateReady != nil }
        XCTAssertEqual(updateReady, false, "Pending uploads still defer an update after capture stops")
        _ = js(jessald, "FairyStackReloadGuard.busy=()=>false; return true;")
        updateReady = nil
        windows.canRestartForUpdate { updateReady = $0 }
        spin { updateReady != nil }
        XCTAssertEqual(updateReady, true, "The same staged update can activate as soon as recording and uploads finish")

    }
}
