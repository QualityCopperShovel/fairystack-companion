import AppKit
import Foundation
import CryptoKit
import Darwin

final class CompanionUpdater {
    struct Manifest: Decodable { let version: String; let download_url: String; let download_sha256: String; let notarized: Bool }
    private let session: URLSession = { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45; return URLSession(configuration: config) }()
    private let status: (String) -> Void
    private let installed: () -> Void
    private var timer: Timer?
    private let updates = UpdateAdmission(currentVersion: "1.1.1")
    init(status: @escaping (String) -> Void, installed: @escaping () -> Void) { self.status = status; self.installed = installed }
    var stagedVersion: String? { updates.stagedVersion }
    func start() { check(); timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.check() } }
    func check(announce: Bool = false) {
        guard updates.begin() else { return }
        var request = URLRequest(url: URL(string: "https://fairystack.com/assets/mac-companion-version.json")!); request.timeoutInterval = 15
        session.dataTask(with: request) { data, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { if announce { self.status("Update check failed") }; self.updates.finish(); return }
            guard self.updates.isNewer(manifest.version) else { if announce { self.status(self.updates.stagedVersion == nil ? "FairyStack Companion is up to date" : "Update installed · takes effect next launch") }; self.updates.finish(); return }
            guard manifest.notarized, let downloadURL = URL(string: manifest.download_url), downloadURL.scheme == "https", downloadURL.host == "fairystack.com" else { self.status("Update manifest is invalid"); self.updates.finish(); return }
            var downloadRequest = URLRequest(url: downloadURL); downloadRequest.timeoutInterval = 30
            self.session.dataTask(with: downloadRequest) { payload, downloadResponse, downloadError in
                guard downloadError == nil, (downloadResponse as? HTTPURLResponse)?.statusCode == 200, let payload else { self.status("Update download failed"); self.updates.finish(); return }
                let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                guard digest == manifest.download_sha256.lowercased() else { self.status("Update verification failed"); self.updates.finish(); return }
                let archive = FileManager.default.temporaryDirectory.appendingPathComponent("fairystack-companion-update-\(UUID().uuidString).zip")
                do { try payload.write(to: archive, options: .atomic); self.install(archive, version: manifest.version) } catch { self.status("Update could not be saved"); self.updates.finish() }
            }.resume()
        }.resume()
    }
    private func run(_ executable: String, _ arguments: [String], deadline: TimeInterval = 120) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FairyStackUpdate", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (exit \(process.terminationStatus))"])
        }
    }
    private func install(_ archive: URL, version: String) {
        DispatchQueue.main.async { self.status("Installing FairyStack Companion update…") }
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(240)
            let manager = FileManager.default
            let work = manager.temporaryDirectory.appendingPathComponent("fairystack-companion-update-\(UUID().uuidString)", isDirectory: true)
            let staged = work.appendingPathComponent("FairyStack Companion.app", isDirectory: true)
            let target = Bundle.main.bundleURL
            let backup = target.deletingLastPathComponent().appendingPathComponent("FairyStack Companion.previous.app", isDirectory: true)
            defer { try? manager.removeItem(at: archive); try? manager.removeItem(at: work); self.updates.finish() }
            do {
                try manager.createDirectory(at: work, withIntermediateDirectories: true)
                try self.run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path], deadline: max(0, min(120, deadline.timeIntervalSinceNow)))
                guard manager.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/FairyStackCompanion").path) else { throw NSError(domain: "FairyStackUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded app is incomplete"]) }
                try self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=anchor apple generic and identifier \"com.fairystack.companion\" and certificate leaf[subject.OU] = \"7ZPTPEXGRC\"", staged.path], deadline: max(0, min(120, deadline.timeIntervalSinceNow)))
                try self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path], deadline: max(0, min(120, deadline.timeIntervalSinceNow)))
                if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
                if manager.fileExists(atPath: target.path) { try manager.moveItem(at: target, to: backup) }
                do { try manager.moveItem(at: staged, to: target) } catch {
                    if manager.fileExists(atPath: backup.path) { try? manager.moveItem(at: backup, to: target) }
                    throw error
                }
                try? manager.removeItem(at: backup)
                self.updates.installed(version)
                self.status("Update installed · restarting…")
                DispatchQueue.main.async(execute: self.installed)
            } catch {
                self.status("Update failed: \(error.localizedDescription)")
            }
        }
    }
}




/// Download and replace the on-disk bundle once; running capture owns its lifetime.
public final class UpdateAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var version: String
    private var staged: String?
    public var stagedVersion: String? { lock.lock(); defer { lock.unlock() }; return staged }
    public init(currentVersion: String) { version = currentVersion }
    public func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }; busy = true; return true
    }
    public func finish() { lock.lock(); busy = false; lock.unlock() }
    public func installed(_ value: String) { lock.lock(); version = value; staged = value; lock.unlock() }
    public func isNewer(_ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let left = candidate.split(separator: ".").compactMap { Int($0) }
        let right = version.split(separator: ".").compactMap { Int($0) }
        guard left.count == 3, right.count == 3 else { return false }
        for index in 0..<3 { if left[index] != right[index] { return left[index] > right[index] } }
        return false
    }
}
