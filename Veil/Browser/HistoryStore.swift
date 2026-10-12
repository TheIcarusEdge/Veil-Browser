import Foundation

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var title: String
    var date: Date
}

/// Browsing history for normal tabs. Only kept while Save History is on.
/// Private tabs are never recorded. Stored in Application Support/history.json.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 2000

    @Published private(set) var entries: [HistoryEntry] = []

    private var saveWork: DispatchWorkItem?

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(url: URL, title: String) {
        guard AppSettings.saveHistory,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = clean.isEmpty ? (url.host ?? url.absoluteString) : clean

        // Revisiting the page you just saw updates that entry instead of adding a duplicate.
        if let first = entries.first, first.url == url {
            entries[0].title = name
            entries[0].date = Date()
        } else {
            entries.insert(HistoryEntry(id: UUID(), url: url, title: name, date: Date()), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        scheduleSave()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func clear() {
        entries = []
        saveWork?.cancel()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    /// Writes are batched so fast browsing doesn't hit the disk on every page.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}
