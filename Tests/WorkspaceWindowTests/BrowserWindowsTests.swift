import AppKit
import WebKit
import Network
import XCTest
@testable import WorkspaceWindow

final class BrowserWindowsTests: XCTestCase {
    private func spin(_ ready: () -> Bool, timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while !ready() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(ready(), "Browser operation reached its test deadline")
    }
    private func js(_ view: WKWebView, _ source: String) -> Any? {
        var done = false, result: Any?
        view.evaluateJavaScript(source) { value,error in XCTAssertNil(error); result = value; done = true }
        spin({ done }); return result
    }
    func testAddressParsingAndTransientLoginExclusion() {
        XCTAssertEqual(BrowserAddress.parse("example.com/path")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserAddress.parse("two words")?.host, "www.google.com")
        for value in ["javascript:alert(1)", "file:///etc/passwd", "https://u:p@example.com", "data:text/html,x"] { XCTAssertNil(BrowserAddress.parse(value)) }
        XCTAssertFalse(BrowserAddress.restorable(URL(string: "https://example.com/?authreturn_handoff=secret")!))
    }
    func testSwitchingTabsKeepsDraftsAndGeneralPagesHaveNoNativeBridge() throws {
        _ = NSApplication.shared
        let suite = "BrowserTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserWindows(version: "test", defaults: defaults)
        defer { while browser.tabCount > 0 { browser.closeTab() }; defaults.removePersistentDomain(forName: suite) }
        let first = browser.addTab(nil)
        first.loadHTMLString("<textarea id='input'>existing draft</textarea><script>window.sent=0;document.addEventListener('submit',()=>sent++)</script>", baseURL: nil)
        spin({ !first.isLoading })
        XCTAssertEqual(js(first, "typeof window.webkit?.messageHandlers?.fairystackConnect") as? String, "undefined")
        XCTAssertEqual(js(first, "typeof window.webkit?.messageHandlers?.fairystackMicrophone") as? String, "undefined")
        var shared = false
        first.callAsyncJavaScript(BrowserDraft.script, arguments: ["text": "page quote"], in: nil, in: .page) { result in
            if case .success(let value) = result { XCTAssertEqual(value as? Bool, true) } else { XCTFail("share failed") }; shared = true
        }
        spin({ shared })
        browser.newTab(); browser.select(0)
        XCTAssertEqual(js(first, "document.querySelector('#input').value") as? String, "existing draft\n\npage quote")
        XCTAssertEqual(js(first, "window.sent") as? Int, 0)
        XCTAssertTrue(browser.preventsUpdateRestart)
    }
    func testNeverRespondingPageTimesOutAndDuplicateActivationReusesTab() throws {
        _ = NSApplication.shared
        let listener = try NWListener(using: .tcp, on: .any)
        var connections: [NWConnection] = []
        listener.newConnectionHandler = { connection in connections.append(connection); connection.start(queue: .main) }
        listener.start(queue: .main)
        defer { listener.cancel(); connections.forEach { $0.cancel() } }
        spin({ listener.port != nil })
        let suite = "BrowserDeadlineTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserWindows(version: "test", defaults: defaults); browser.loadDeadline = 0.4
        defer { while browser.tabCount > 0 { browser.closeTab() }; defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/never")!
        browser.open(url); browser.open(url)
        XCTAssertEqual(browser.tabCount, 1)
        spin({ browser.statusText.contains("timed out") })
        let view = try XCTUnwrap(browser.selectedView)
        browser.webViewWebContentProcessDidTerminate(view)
        XCTAssertTrue(browser.statusText.contains("process stopped"))
        browser.prepareToQuit()
        let saved = try JSONDecoder().decode(BrowserSnapshot.self, from: XCTUnwrap(defaults.data(forKey: "browser.windows.v1")))
        XCTAssertTrue(saved.urls.isEmpty, "Unfinished navigation is not restored as a successful saved page")
    }
    func testRestoreFiltersOneTimeHandoffsAndKeepsSelectedTab() throws {
        _ = NSApplication.shared
        let suite = "BrowserRestoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let urls = [URL(string: "https://example.com/one")!, URL(string: "https://example.com/two")!]
        defaults.set(try JSONEncoder().encode(BrowserSnapshot(urls: urls, selected: 1, open: true)), forKey: "browser.windows.v1")
        let browser = BrowserWindows(version: "test", defaults: defaults)
        browser.restore()
        XCTAssertEqual(browser.tabCount, 2)
        browser.prepareToQuit()
        let snapshot = try JSONDecoder().decode(BrowserSnapshot.self, from: XCTUnwrap(defaults.data(forKey: "browser.windows.v1")))
        XCTAssertEqual(snapshot.urls, urls); XCTAssertEqual(snapshot.selected, 1)
        while browser.tabCount > 0 { browser.closeTab() }
        defaults.removePersistentDomain(forName: suite)
    }
}
