import AppKit
import AVFoundation
import WebKit

/// Main-thread owner of site consent. TCC remains an independent OS gate.
/// No consent is migrated from cookies, app installation or OS authorization.
final class MicrophoneConsent {
    static let key = "microphoneOriginConsent.v1"
    private let store: SavedStacks
    var systemAllowsRequest: () -> Bool = {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized || status == .notDetermined
    }
    var timeout: TimeInterval = 60
    var present: (URL, NSWindow, @escaping (Bool) -> Void) -> (() -> Void) = { origin, window, reply in
        let alert = NSAlert()
        alert.messageText = "Allow microphone for this FairyStack?"
        alert.informativeText = "\(origin.absoluteString)\n\nRemember this choice on this Mac across reloads and app updates. Recording starts only when you start the microphone. macOS microphone permission is also required. Change this later with Reset microphone permission for this stack in the FairyStack menu. This request expires after one minute."
        alert.addButton(withTitle: "Allow and Remember")
        alert.addButton(withTitle: "Don’t Allow")
        alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
        return { if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .abort) } }
    }
    private final class Pending {
        let id = UUID()
        let origin: URL
        let valid: () -> Bool
        var replies: [(WKPermissionDecision) -> Void]
        var cancel: (() -> Void)?
        var timer: DispatchWorkItem?
        init(origin: URL, valid: @escaping () -> Bool, reply: @escaping (WKPermissionDecision) -> Void) {
            self.origin = origin; self.valid = valid; replies = [reply]
        }
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    var hasPending: Bool { !pending.isEmpty }
    init(store: SavedStacks) { self.store = store }
    private func saved(_ origin: URL) -> Bool { store.entries.contains { $0.url == origin } }
    private var decisions: [String: Bool] {
        get { store.defaults.dictionary(forKey: Self.key) as? [String: Bool] ?? [:] }
        set { store.defaults.set(newValue, forKey: Self.key) }
    }
    func request(owner: AnyObject, origin: URL, window: NSWindow?, valid: @escaping () -> Bool,
                 reply: @escaping (WKPermissionDecision) -> Void) {
        guard valid(), systemAllowsRequest() else { reply(.deny); return }
        // Trials retain WebKit's ephemeral prompt; never write a durable choice.
        if origin.host == WorkspaceAddress.trialOrigin.host { reply(.prompt); return }
        guard saved(origin), let window else { reply(.deny); return }
        if let allowed = decisions[origin.absoluteString] { reply(allowed ? .grant : .deny); return }
        let key = ObjectIdentifier(owner)
        if let existing = pending[key] {
            guard existing.origin == origin else { reply(.deny); return }
            existing.replies.append(reply); return
        }
        // One visible consent sheet per origin; another window may retry after it settles.
        guard !pending.values.contains(where: { $0.origin == origin }), window.attachedSheet == nil else { reply(.deny); return }
        let request = Pending(origin: origin, valid: valid, reply: reply)
        pending[key] = request
        let timer = DispatchWorkItem { [weak self] in self?.finish(key, id: request.id, allowed: nil) }
        request.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
        let cancel = present(origin, window) { [weak self] allowed in self?.finish(key, id: request.id, allowed: allowed) }
        // Injected presenters can finish synchronously; never leave a sheet orphaned.
        if pending[key]?.id == request.id { request.cancel = cancel } else { cancel() }
    }
    private func finish(_ key: ObjectIdentifier, id: UUID, allowed: Bool?) {
        guard let request = pending[key], request.id == id else { return }
        pending.removeValue(forKey: key)
        request.timer?.cancel(); request.cancel?()
        var decision = WKPermissionDecision.deny
        if let allowed, request.valid(), saved(request.origin), systemAllowsRequest() {
            var values = decisions; values[request.origin.absoluteString] = allowed; decisions = values
            decision = allowed ? .grant : .deny
        }
        request.replies.forEach { $0(decision) }
    }
    func cancel(owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if let request = pending[key] { finish(key, id: request.id, allowed: nil) }
    }
    func reset(_ origin: URL) {
        for (key, request) in Array(pending) where request.origin == origin { finish(key, id: request.id, allowed: nil) }
        var values = decisions; values.removeValue(forKey: origin.absoluteString); decisions = values
    }
    func cancelAll() {
        for (key, request) in Array(pending) { finish(key, id: request.id, allowed: nil) }
    }
}
