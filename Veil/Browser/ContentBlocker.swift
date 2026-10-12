import Foundation
import WebKit

/// Compiles the bundled ad and tracker rules into WebKit's native content blocker.
/// The compiled list is cached by WebKit, so it only compiles again when the list changes.
enum ContentBlocker {
    /// Bump this whenever blocklist.json changes so the cached copy is replaced.
    static let listVersion = "3"
    static var identifier: String { "veil-blocklist-v\(listVersion)" }

    static func compile(completion: @escaping (WKContentRuleList?) -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            completion(nil)
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { cached, _ in
            if let cached {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            guard let url = Bundle.main.url(forResource: "blocklist", withExtension: "json"),
                  let json = try? String(contentsOf: url, encoding: .utf8) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { print("Blocklist failed to compile: \(error)") }
                removeOldLists(from: store)
                DispatchQueue.main.async { completion(list) }
            }
        }
    }

    private static func removeOldLists(from store: WKContentRuleListStore) {
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id != identifier {
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
        }
    }
}
