import Foundation

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, brave, startpage, google

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        case .google: return "Google"
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        let param: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"; param = "q"
        case .brave: base = "https://search.brave.com/search"; param = "q"
        case .startpage: base = "https://www.startpage.com/sp/search"; param = "query"
        case .google: base = "https://www.google.com/search"; param = "q"
        }
        var parts = URLComponents(string: base)
        parts?.queryItems = [URLQueryItem(name: param, value: query)]
        return parts?.url
    }
}

enum AppSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "searchEngine": SearchEngine.duckDuckGo.rawValue,
            "blockTrackers": true,
            "httpsOnly": true,
            "lockPrivateTabs": true,
            "clearOnBackground": false,
            "restoreTabs": true,
            "saveHistory": false,
        ])
    }

    static var blockTrackers: Bool { UserDefaults.standard.bool(forKey: "blockTrackers") }
    static var restoreTabs: Bool { UserDefaults.standard.bool(forKey: "restoreTabs") }
    static var saveHistory: Bool { UserDefaults.standard.bool(forKey: "saveHistory") }

    // MARK: Sites with ad blocking turned off

    private static let blockingOffKey = "blockingOffHosts"

    static var blockingOffHosts: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: blockingOffKey) ?? [])
    }

    /// Matches the site and its subdomains, ignoring a leading "www.".
    static func isBlockingOff(for host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return blockingOffHosts.contains { off in host == off || host.hasSuffix("." + off) }
    }

    static func setBlockingOff(_ off: Bool, for host: String) {
        let site = siteName(host)
        var hosts = blockingOffHosts
        if off { hosts.insert(site) } else {
            hosts = hosts.filter { !(site == $0 || site.hasSuffix("." + $0)) }
        }
        UserDefaults.standard.set(hosts.sorted(), forKey: blockingOffKey)
    }

    static func siteName(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    // Saved normal tabs. Private tabs are never written here.
    static let savedTabsKey = "savedTabs"
    static let savedTabIndexKey = "savedTabIndex"
    static var httpsOnly: Bool { UserDefaults.standard.bool(forKey: "httpsOnly") }

    static var engine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .duckDuckGo
    }

    /// Turns what the person typed into a URL: a full address, a bare domain, or a search.
    static func destination(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host != nil {
            return url
        }
        if !text.contains(" "), text.contains("."),
           let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        return engine.url(for: text)
    }
}
