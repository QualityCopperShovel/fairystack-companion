import Foundation

/// Content-free evidence, scoped to the requesting stack. No network credentials,
/// command pairing, audio, transcript text, file paths or raw crash reports.
final class NativeDiagnostics {
    static let queueKey = "nativeDiagnostics.queue.v1"
    static let runKey = "nativeDiagnostics.run.v1"
    static let seenKey = "nativeDiagnostics.crashes.v1"
    private let defaults: UserDefaults
    private let version: String
    private let now: () -> Date
    private(set) var runID = UUID().uuidString
    private var started = false
    private var origins = Set<String>()
    private var capturing: [String: Bool] = [:]
    private var scanning = false
    private var lastScan = Date.distantPast
    var crashFiles: () throws -> [URL] = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        return files.filter { $0.lastPathComponent.hasPrefix("FairyStack") && $0.pathExtension == "ips" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    init(defaults: UserDefaults, version: String, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.version = version; self.now = now
    }
    func start() {
        guard !started else { return }; started = true
        if let old = defaults.dictionary(forKey: Self.runKey), old["clean"] as? Bool == false,
           let previousOrigins = old["origins"] as? [String], let previousID = old["id"] as? String {
            let states = old["capture"] as? [String: Bool] ?? [:]
            for origin in previousOrigins.prefix(20) {
                var event = make("native_unclean_exit")
                event["id"] = previousID; event["run_id"] = previousID; event["client_version"] = old["version"] as? String ?? version
                event["microphone_active"] = states[origin] ?? false
                enqueue(event, origin: origin)
            }
        }
        persist(clean: false)
    }
    func saw(origin: URL, microphoneActive: Bool? = nil) {
        start(); origins.insert(origin.absoluteString)
        if let microphoneActive { capturing[origin.absoluteString] = microphoneActive }
        persist(clean: false)
    }
    func finish() { if started { persist(clean: true) } }
    private func persist(clean: Bool) {
        defaults.set(["id": runID, "version": version, "clean": clean, "origins": Array(origins), "capture": capturing], forKey: Self.runKey)
        defaults.synchronize()
    }
    private func make(_ kind: String) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ["id": UUID().uuidString, "event": kind, "source": "native", "run_id": runID,
                "observed_at": now().timeIntervalSince1970, "client_version": version,
                "os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
    }
    func webProcessTerminated(origin: URL, microphoneActive: Bool) {
        let wasActive = microphoneActive || capturing[origin.absoluteString] == true
        saw(origin: origin, microphoneActive: false)
        var event = make("web_process_terminated"); event["microphone_active"] = wasActive
        enqueue(event, origin: origin.absoluteString)
    }
    private func enqueue(_ event: [String: Any], origin: String) {
        var queue = defaults.array(forKey: Self.queueKey) as? [[String: Any]] ?? []
        queue.removeAll { (($0["event"] as? [String: Any])?["observed_at"] as? Double ?? 0) < now().timeIntervalSince1970 - 14 * 86400 }
        queue.append(["origin": origin, "event": event])
        // A bounded local journal survives renderer and app termination.
        if queue.count > 200 {
            let dropped = queue.count - 199
            queue.removeFirst(dropped)
            var gap = make("evidence_dropped"); gap["reason"] = "capacity"; gap["count"] = dropped
            queue.append(["origin": origin, "event": gap])
        }
        defaults.set(queue, forKey: Self.queueKey)
        defaults.synchronize()
    }
    func snapshot(origin: URL) -> [[String: Any]] {
        (defaults.array(forKey: Self.queueKey) as? [[String: Any]] ?? [])
            .filter { $0["origin"] as? String == origin.absoluteString }
            .compactMap { $0["event"] as? [String: Any] }.prefix(100).map { $0 }
    }
    func acknowledge(_ ids: [String], origin: URL) {
        let accepted = Set(ids)
        var queue = defaults.array(forKey: Self.queueKey) as? [[String: Any]] ?? []
        queue.removeAll { row in
            row["origin"] as? String == origin.absoluteString && accepted.contains((row["event"] as? [String: Any])?["id"] as? String ?? "")
        }
        defaults.set(queue, forKey: Self.queueKey)
        defaults.synchronize()
    }
    /// Reading is off the UI thread, at most 20 bounded reports and three seconds.
    func collectCrashes(origin: URL, completion: @escaping () -> Void) {
        guard !scanning, now().timeIntervalSince(lastScan) >= 30 else { completion(); return }
        scanning = true; lastScan = now()
        let files = crashFiles, cutoff = now().addingTimeInterval(-14 * 86400)
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(3)
            var found: [[String: Any]] = []
            var scanReason: String?
            var reports: [URL] = []
            do { reports = try files() } catch { scanReason = "permission" }
            for url in reports.prefix(20) {
                if Date() >= deadline { scanReason = "deadline"; break }
                guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = attrs.fileSize, size <= 2_000_000,
                      let modified = attrs.contentModificationDate, modified >= cutoff,
                      let data = try? Data(contentsOf: url), let event = Self.crashSummary(data, observed: modified) else { continue }
                found.append(event)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(); return }
                var scan = self.make("native_scan")
                scan["state"] = scanReason == nil ? "completed" : "failed"; scan["count"] = found.count
                if let scanReason { scan["reason"] = scanReason }
                self.enqueue(scan, origin: origin.absoluteString)
                var seen = self.defaults.stringArray(forKey: Self.seenKey) ?? []
                for summary in found {
                    guard let id = summary["crash_id"] as? String, !seen.contains(id) else { continue }
                    var event = self.make("native_crash")
                    event["id"] = id
                    event.removeValue(forKey: "run_id") // Crash report alone cannot identify a browser run or causal window.
                    event.removeValue(forKey: "client_version"); event.removeValue(forKey: "os_version")
                    for (key, value) in summary { event[key] = value }
                    self.enqueue(event, origin: origin.absoluteString); seen.append(id)
                }
                self.defaults.set(Array(seen.suffix(200)), forKey: Self.seenKey)
                self.scanning = false; completion()
            }
        }
    }
    static func crashSummary(_ data: Data, observed: Date) -> [String: Any]? {
        guard data.count <= 2_000_000, let newline = data.firstIndex(of: 10),
              let header = (try? JSONSerialization.jsonObject(with: data[..<newline])) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any],
              let bundle = body["bundleInfo"] as? [String: Any], bundle["CFBundleIdentifier"] as? String == "com.fairystack.companion",
              body["procName"] as? String == "FairyStackCompanion",
              let incident = (header["incident_id"] ?? body["incident"]) as? String, UUID(uuidString: incident) != nil else { return nil }
        var result: [String: Any] = ["crash_id": incident, "observed_at": observed.timeIntervalSince1970]
        func safe(_ value: Any?) -> String? {
            guard let text = value as? String, text.range(of: "^[A-Za-z0-9_.() -]{1,80}$", options: .regularExpression) != nil else { return nil }; return text
        }
        if let value = safe(bundle["CFBundleShortVersionString"]) { result["client_version"] = value }
        if let os = body["osVersion"] as? [String: Any], let value = safe(os["train"]) { result["os_version"] = value }
        if let exception = body["exception"] as? [String: Any], let value = safe(exception["type"]) { result["exception_type"] = value }
        if let termination = body["termination"] as? [String: Any] {
            if let value = safe(termination["namespace"]) { result["termination_namespace"] = value }
            if let code = termination["code"] as? Int, code >= 0, code <= 9_007_199_254_740_991 { result["termination_code"] = code }
        }
        if let images = body["usedImages"] as? [[String: Any]], let image = images.firstIndex(where: { $0["name"] as? String == "FairyStackCompanion" }),
           let uuid = images[image]["uuid"] as? String, UUID(uuidString: uuid) != nil {
            result["image_uuid"] = uuid
            if let fault = body["faultingThread"] as? Int, let threads = body["threads"] as? [[String: Any]], threads.indices.contains(fault),
               let frames = threads[fault]["frames"] as? [[String: Any]] {
                result["frame_offsets"] = frames.filter { $0["imageIndex"] as? Int == image }.compactMap { $0["imageOffset"] as? Int }.filter { $0 >= 0 && $0 <= 9_007_199_254_740_991 }.prefix(8).map { $0 }
            }
        }
        return result
    }
}
