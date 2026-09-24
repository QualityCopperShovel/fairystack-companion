import Foundation

struct SavedStack: Codable, Equatable {
    let url: URL
    var name: String
}
struct SavedStackWindow: Codable, Equatable {
    let origin: URL
    let url: URL
}

/// Local bookmarks only. No account directory, command authority, or login credentials.
final class SavedStacks {
    static let key = "savedFairyStacks.v1"
    static let selectedKey = "selectedFairyStack.v1"
    static let windowsKey = "fairyStackWindows.v1"
    let defaults: UserDefaults
    private(set) var entries: [SavedStack] = []
    var selected: URL? {
        guard let text = defaults.string(forKey: Self.selectedKey), let url = WorkspaceAddress.parse(text), entries.contains(where: { $0.url == url }) else { return entries.first?.url }
        return url
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([SavedStack].self, from: data) {
            for entry in saved {
                guard let url = Self.permanent(entry.url), !entries.contains(where: { $0.url == url }) else { continue }
                entries.append(SavedStack(url: url, name: Self.name(entry.name) ?? Self.defaultName(url)))
            }
        }
        migrate(pairedOrigin: nil)
    }
    static func permanent(_ url: URL) -> URL? {
        guard let canonical = WorkspaceAddress.parse(url.absoluteString), canonical.host != WorkspaceAddress.trialOrigin.host,
              canonical.host != "fairystack.com", canonical.host != "www.fairystack.com" else { return nil }
        return canonical
    }
    static func name(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { return nil }
        return value
    }
    static func defaultName(_ url: URL) -> String {
        // Keep the complete host visible: similar names on different domains are distinguishable.
        (url.host ?? "FairyStack") + (url.port.map { ":\($0)" } ?? "")
    }
    func migrate(pairedOrigin: URL?) {
        let previous = selected
        if let old = defaults.string(forKey: WorkspaceAddress.defaultsKey).flatMap(WorkspaceAddress.parse) { add(old) }
        defaults.removeObject(forKey: WorkspaceAddress.defaultsKey)
        // Pairing is a fallback for old installations, never a source of command authority here.
        if let pairedOrigin, !defaults.bool(forKey: "pairedStackMigrated.v1") {
            if entries.isEmpty { add(pairedOrigin) }
            defaults.set(true, forKey: "pairedStackMigrated.v1")
        }
        if let previous { select(previous) }
        save()
    }
    func add(_ candidate: URL) {
        guard let url = Self.permanent(candidate) else { return }
        if !entries.contains(where: { $0.url == url }) { entries.append(SavedStack(url: url, name: Self.defaultName(url))) }
        select(url); save()
    }
    func select(_ url: URL) {
        guard entries.contains(where: { $0.url == url }) else { return }
        defaults.set(url.absoluteString, forKey: Self.selectedKey)
    }
    @discardableResult func rename(_ url: URL, to text: String) -> Bool {
        guard let name = Self.name(text), let index = entries.firstIndex(where: { $0.url == url }) else { return false }
        entries[index].name = name; save(); return true
    }
    func remove(_ url: URL) {
        entries.removeAll { $0.url == url }; save()
        windows = windows.filter { $0.origin != url }
    }
    private func save() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) } }
    var hasWindowSnapshot: Bool { defaults.data(forKey: Self.windowsKey) != nil }
    var windows: [SavedStackWindow] {
        get {
            guard let data = defaults.data(forKey: Self.windowsKey), let records = try? JSONDecoder().decode([SavedStackWindow].self, from: data) else { return [] }
            return records.filter { record in
                entries.contains(where: { $0.url == record.origin }) && WorkspaceAddress.sameOrigin(record.url, record.origin)
            }
        }
        set {
            let records = newValue.filter { record in
                entries.contains(where: { $0.url == record.origin }) && WorkspaceAddress.sameOrigin(record.url, record.origin)
            }
            if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.windowsKey) }
        }
    }
}
