import AppKit
import Foundation
import Security
import CommandRunner

// The standalone app has its own explicitly paired Keychain authority.
final class FairyStackCommands: NSObject, @unchecked Sendable {
    let menu = NSMenuItem(title: "FairyStack commands: Off…", action: nil, keyEquivalent: "")
    let activityMenu = NSMenuItem(title: "Open Mac command activity…", action: nil, keyEquivalent: "")
    private var origin: URL?
    private var token: String?
    private var root: URL?
    private var timer: Timer?
    private var busy = false
    private var generation = 0
    private var runner: OpaquePointer?
    private var active: [String: Any]?
    private var requestTask: URLSessionDataTask?
    private var pendingResult: [String: Any]?
    private var reportDeadline: Date?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 10
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private let service = "com.fairystack.companion.connection"
    private let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FairyStack/Commands", isDirectory: true)
    override init() {
        super.init()
        menu.target = self; menu.action = #selector(configure)
        activityMenu.target = self; activityMenu.action = #selector(openActivity)
    }
    var pairedOrigin: URL? { origin }
    var preventsUpdateRestart: Bool { runner != nil || active != nil || pendingResult != nil }
    func start() {
        var result: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "connection", kSecReturnData as String: true]
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
           let bytes = result as? Data, let saved = try? JSONSerialization.jsonObject(with: bytes) as? [String:String],
           let url = saved["origin"].flatMap(URL.init(string:)), let value = saved["token"], let folder = saved["root"] {
            origin = url; token = value; root = URL(fileURLWithPath: folder)
            activate()
        }
    }
    private func activate() {
        menu.title = "FairyStack commands: Connecting…"
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    @objc func configure() {
        NSApp.activate(ignoringOtherApps: true)
        if token == nil && runner != nil { showError("The previous command is still stopping. Try again in a moment."); return }
        if token != nil {
            let a = NSAlert(); a.messageText = "Disconnect FairyStack commands?"
            a.informativeText = "This stops the active command and revokes access from \(origin?.host ?? "FairyStack")."
            a.addButton(withTitle: "Disconnect"); a.addButton(withTitle: "Keep connected")
            if a.runModal() == .alertFirstButtonReturn { disconnect() }
            return
        }
        let a = NSAlert(); a.messageText = "Connect FairyStack commands"
        a.informativeText = "Paste the connection code from FairyStack’s Mac pairing page. Agents for that account can run shell commands as your Mac user. Commands start in your home folder and use your Mac account’s file access. Password and administrator prompts cannot be answered remotely."
        let field = NSSecureTextField(frame: NSRect(x: 0,y: 0,width: 420,height: 28)); a.accessoryView = field
        a.addButton(withTitle: "Connect"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count == 2, let url = URL(string: parts[0]), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", parts[1].hasPrefix("fs_mac_"), parts[1].count < 100 else {
            showError("Invalid connection code. Create a new code on your FairyStack Mac pairing page."); return
        }
        do { try saveConnection(origin: url, token: parts[1]) }
        catch { showError(error.localizedDescription) }
    }
    private func saveConnection(origin url: URL, token value: String) throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let data = try JSONSerialization.data(withJSONObject: ["origin":url.absoluteString,"token":value,"root":folder.path])
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"connection"]
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary,nil)
        guard status == errSecSuccess else { throw NSError(domain:"Keychain",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"Could not save the connection in Keychain."]) }
        origin = url; token = value; root = folder; activate()
    }
    func connectFromWindow(origin: URL, token: String, window: NSWindow, completion: @escaping (String?) -> Void) {
        guard self.token == nil, runner == nil else { completion("This Mac is already connected. Disconnect it before pairing again."); return }
        do { try saveConnection(origin: origin, token: token); completion(nil) }
        catch { completion(error.localizedDescription) }
    }
    private func showError(_ text:String) { let a = NSAlert(); a.messageText = "FairyStack commands"; a.informativeText = text; a.runModal() }
    @objc private func openActivity() {
        try? FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        NSWorkspace.shared.open(logs)
    }
    func stop() {
        generation += 1; timer?.invalidate(); timer = nil; requestTask?.cancel(); requestTask = nil; busy = false
        pendingResult = nil; reportDeadline = nil
        if let runner { fs_command_cancel(runner) }
    }
    private func disconnect() {
        let oldOrigin = origin, oldToken = token
        stop(); token = nil; origin = nil; root = nil
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"connection"] as CFDictionary)
        menu.title = "FairyStack commands: Off…"
        if let oldOrigin, let oldToken {
            var r = URLRequest(url:oldOrigin.appendingPathComponent("api/companions/device/revoke")); r.httpMethod = "POST"; r.timeoutInterval = 8
            r.setValue(oldToken,forHTTPHeaderField:"X-FairyStack-Agent-Token")
            session.dataTask(with:r) { _,_,_ in }.resume()
        }
    }
    private func output() -> String {
        guard let runner else { return "" }
        var bytes = [CChar](repeating:0,count:131072)
        let count = fs_command_output(runner,&bytes,bytes.count)
        let raw = bytes.prefix(Int(count)).map { UInt8(bitPattern:$0) }
        // Keep JSON within the wire limit even when invalid UTF-8 expands to replacement characters.
        let text = String(decoding:raw,as:UTF8.self)
        return String(decoding:Array(text.utf8.prefix(130000)),as:UTF8.self)
    }
    private func tick() {
        guard !busy, let origin, let token, let root else { return }
        if pendingResult != nil, let reportDeadline, Date() > reportDeadline {
            pendingResult = nil; self.reportDeadline = nil
            menu.title = "FairyStack commands: Result delivery failed · reconnect"
            stop(); return
        }
        let path: String
        let body: [String:Any]
        if let pendingResult { path = "report"; body = pendingResult }
        else if let active { path = "report"; body = ["id":active["id"]!,"state":"running","output":output()] }
        else { path = "poll"; body = ["root":root.path] }
        busy = true
        let ticket = generation
        var r = URLRequest(url:origin.appendingPathComponent("api/companions/device/"+path)); r.httpMethod = "POST"; r.timeoutInterval = 8
        r.setValue(token,forHTTPHeaderField:"X-FairyStack-Agent-Token"); r.setValue("application/json",forHTTPHeaderField:"Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject:body)
        requestTask = session.dataTask(with:r) { [weak self] data,response,error in
            DispatchQueue.main.async {
                guard let self, ticket == self.generation else { return }
                self.busy = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data, let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {
                    if let runner = self.runner { fs_command_cancel(runner) }
                    self.menu.title = "FairyStack commands: Disconnected · retrying"
                    if status == 401 || status == 403 { self.disconnect(); self.menu.title = "FairyStack commands: Access expired · pair again" }
                    return
                }
                if path == "report" {
                    guard let _ = value["state"] as? String, let stop = value["stop"] as? Bool else {
                        if let runner = self.runner { fs_command_cancel(runner) }; self.menu.title = "FairyStack commands: Invalid server response"; self.stop(); return
                    }
                    if stop, let runner = self.runner { fs_command_cancel(runner) }
                    if body["state"] as? String != "running" { self.pendingResult = nil; self.reportDeadline = nil }
                } else if let command = value["command"] as? [String:Any] {
                    self.execute(command,serverTime:value["server_time"] as? Double)
                } else if value["command"] is NSNull {
                    self.menu.title = "FairyStack commands: Ready · \(origin.host ?? "")"
                } else { self.menu.title = "FairyStack commands: Invalid server response"; self.stop() }
            }
        }
        requestTask?.resume()
    }
    private func journal(_ value:[String:Any]) {
        do {
            try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let url = logs.appendingPathComponent("\(value["id"] as? String ?? UUID().uuidString).json")
            let bytes = try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
            try bytes.write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch { menu.title = "FairyStack commands: Cannot save activity" }
    }
    private func execute(_ job:[String:Any],serverTime:Double?) {
        guard runner == nil, let root, let id = job["id"] as? String,
              id.range(of:"^[a-f0-9]{24}$",options:.regularExpression) != nil,
              let command = job["command"] as? String, let cwd = job["cwd"] as? String,
              let deadline = job["deadline"] as? Double, let serverTime else { stop(); menu.title = "FairyStack commands: Invalid command"; return }
        let directory = root.appendingPathComponent(cwd).resolvingSymlinksInPath().standardizedFileURL
        let seconds = min(1800,deadline-serverTime-2)
        guard (directory.path == root.path || directory.path.hasPrefix(root.path+"/")), seconds > 0,
              FileManager.default.fileExists(atPath:directory.path) else {
            pendingResult = ["id":id,"state":"failed","error":"Working folder is unavailable or command deadline elapsed.","output":""]
            reportDeadline = Date().addingTimeInterval(30); return
        }
        guard let handle = fs_command_create() else { stop(); return }
        runner = handle; active = job
        journal(job); menu.title = "FairyStack commands: Running · \(id.prefix(8))"
        let ticket = generation
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = fs_command_run(handle,command,directory.path,seconds)
            DispatchQueue.main.async {
                guard let self else { fs_command_destroy(handle); return }
                let text = self.output()
                fs_command_destroy(handle); self.runner = nil; self.active = nil
                let state = result == 0 ? "completed" : result == -3 ? "timed_out" : result == -2 ? "cancelled" : "failed"
                var report:[String:Any] = ["id":id,"state":state,"output":text,"exit_code":Int(result),"finished_local":Date().timeIntervalSince1970]
                if result != 0 { report["error"] = result == -3 ? "Local command deadline elapsed." : result == -2 ? "Command stopped locally or connection was lost." : "Command exited with status \(result)." }
                self.journal(job.merging(report) { _,new in new })
                guard ticket == self.generation else { return }
                self.pendingResult = report; self.reportDeadline = Date().addingTimeInterval(30)
                self.menu.title = "FairyStack commands: \(state) · \(id.prefix(8))"
                self.tick()
            }
        }
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
