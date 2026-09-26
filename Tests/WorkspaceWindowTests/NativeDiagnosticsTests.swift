import XCTest
@testable import WorkspaceWindow

final class NativeDiagnosticsTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    let origin = URL(string: "https://owner.fairystack.com")!
    let other = URL(string: "https://other.fairystack.com")!
    override func setUp() { suite = "diagnostics-tests-" + UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    func journal() -> NativeDiagnostics {
        let value = NativeDiagnostics(defaults: defaults, version: "1.10.0")
        value.crashFiles = { [] }; return value
    }
    func testAbruptExitIsNotCalledACrashAndSurvivesRelaunch() {
        let first = journal(); first.saw(origin: origin, microphoneActive: true)
        let second = journal(); second.start()
        let event = second.snapshot(origin: origin).first!
        XCTAssertEqual(event["event"] as? String, "native_unclean_exit")
        XCTAssertEqual(event["run_id"] as? String, first.runID)
        XCTAssertEqual(event["microphone_active"] as? Bool, true)
        XCTAssertTrue(second.snapshot(origin: other).isEmpty)
        second.acknowledge([event["id"] as! String], origin: other)
        XCTAssertEqual(second.snapshot(origin: origin).count, 1)
        second.acknowledge([event["id"] as! String], origin: origin)
        XCTAssertTrue(second.snapshot(origin: origin).isEmpty)
    }
    func testCleanQuitDoesNotProduceUncleanExitAndRendererFailureIsSeparate() {
        let first = journal(); first.saw(origin: origin); first.finish()
        let second = journal(); second.start()
        XCTAssertTrue(second.snapshot(origin: origin).isEmpty)
        second.webProcessTerminated(origin: origin, microphoneActive: true)
        let event = second.snapshot(origin: origin).first!
        XCTAssertEqual(event["event"] as? String, "web_process_terminated")
        XCTAssertEqual(event["microphone_active"] as? Bool, true)
        XCTAssertEqual(journal().snapshot(origin: origin).count, 1)
    }
    func testCrashSummaryRequiresOurProcessAndNeverContainsPathsOrText() throws {
        let incident = UUID().uuidString, image = UUID().uuidString
        let header: [String: Any] = ["incident_id": incident, "secret": "never upload"]
        var body: [String: Any] = ["procName": "FairyStackCompanion", "procPath": "/Users/private/FairyStack.app",
            "bundleInfo": ["CFBundleIdentifier": "com.fairystack.companion", "CFBundleShortVersionString": "1.9.3"],
            "exception": ["type": "EXC_BAD_ACCESS", "message": "private text"],
            "termination": ["namespace": "SIGNAL", "code": 11],
            "usedImages": [["name": "FairyStackCompanion", "uuid": image, "path": "/private/image"]],
            "faultingThread": 0, "threads": [["frames": [["imageIndex": 0, "imageOffset": 1234, "symbol": "private symbol"]]]]]
        func encode() throws -> Data { try JSONSerialization.data(withJSONObject: header) + Data([10]) + JSONSerialization.data(withJSONObject: body) }
        let summary = try XCTUnwrap(NativeDiagnostics.crashSummary(encode(), observed: Date()))
        XCTAssertEqual(summary["crash_id"] as? String, incident)
        XCTAssertEqual(summary["exception_type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertEqual(summary["frame_offsets"] as? [Int], [1234])
        XCTAssertEqual(summary["client_version"] as? String, "1.9.3")
        let encoded = String(data: try JSONSerialization.data(withJSONObject: summary), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("private")); XCTAssertFalse(encoded.contains("never upload"))
        body["procName"] = "UnrelatedApp"
        XCTAssertNil(try NativeDiagnostics.crashSummary(encode(), observed: Date()))
        XCTAssertNil(NativeDiagnostics.crashSummary(Data("not JSON".utf8), observed: Date()))
    }
}
