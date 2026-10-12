import Foundation
import WebKit

/// Compiles the bundled tracker and ad rules into WebKit's native content blocker.
enum ContentBlocker {
    static func compile(completion: @escaping (WKContentRuleList?) -> Void) {
        guard let url = Bundle.main.url(forResource: "blocklist", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            completion(nil)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "veil-trackers",
            encodedContentRuleList: json
        ) { list, error in
            if let error { print("Blocklist failed to compile: \(error)") }
            DispatchQueue.main.async { completion(list) }
        }
    }
}
