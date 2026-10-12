import Foundation
import LocalAuthentication
import WebKit

final class TabStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var currentID: UUID?
    @Published var privateLocked = false

    private var blockList: WKContentRuleList?

    init() {
        if !restoreSavedTabs() {
            newTab(isPrivate: false)
        }
        ContentBlocker.compile { [weak self] list in
            self?.blockList = list
            self?.applyBlocking()
        }
    }

    var current: BrowserTab? {
        tabs.first { $0.id == currentID } ?? tabs.first
    }

    var hasPrivateTabs: Bool { tabs.contains { $0.isPrivate } }

    @discardableResult
    func newTab(isPrivate: Bool) -> BrowserTab {
        let tab = BrowserTab(isPrivate: isPrivate, blockList: AppSettings.blockTrackers ? blockList : nil)
        tabs.append(tab)
        currentID = tab.id
        return tab
    }

    func select(_ tab: BrowserTab) {
        currentID = tab.id
        tab.loadPendingIfNeeded()
    }

    // MARK: Saving tabs

    /// Saves the addresses of normal tabs. Private tabs are never saved.
    func saveTabs() {
        let defaults = UserDefaults.standard
        guard AppSettings.restoreTabs else {
            forgetSavedTabs()
            return
        }
        let normal = tabs.filter { !$0.isPrivate }
        let urls = normal.compactMap { $0.savedURL?.absoluteString }
        defaults.set(urls, forKey: AppSettings.savedTabsKey)

        // Remember which normal tab was open, counting only tabs that have an address.
        let withURL = normal.filter { $0.savedURL != nil }
        let selected = current.flatMap { cur in withURL.firstIndex { $0.id == cur.id } }
        defaults.set(selected ?? max(withURL.count - 1, 0), forKey: AppSettings.savedTabIndexKey)
    }

    func forgetSavedTabs() {
        UserDefaults.standard.removeObject(forKey: AppSettings.savedTabsKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.savedTabIndexKey)
    }

    /// Recreates saved tabs at launch. Returns false when there was nothing to restore.
    private func restoreSavedTabs() -> Bool {
        guard AppSettings.restoreTabs,
              let saved = UserDefaults.standard.stringArray(forKey: AppSettings.savedTabsKey) else { return false }
        let urls = saved.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return false }

        for url in urls {
            newTab(isPrivate: false).restore(url)
        }
        let index = min(max(UserDefaults.standard.integer(forKey: AppSettings.savedTabIndexKey), 0), tabs.count - 1)
        select(tabs[index])
        return true
    }

    func close(_ tab: BrowserTab) {
        tab.webView.stopLoading()
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty {
            newTab(isPrivate: false)
        } else if currentID == tab.id, let last = tabs.last {
            select(last)
        }
    }

    func closeAllPrivate() {
        for tab in tabs.filter({ $0.isPrivate }) { close(tab) }
        privateLocked = false
    }

    func showNormalTab() {
        if let normal = tabs.last(where: { !$0.isPrivate }) {
            select(normal)
        } else {
            newTab(isPrivate: false)
        }
    }

    func applyBlocking() {
        let list = AppSettings.blockTrackers ? blockList : nil
        tabs.forEach { $0.setBlocking(list) }
    }

    /// Clears cookies and site data for normal tabs. Private tabs never store any.
    func clearBrowsingData(completion: (() -> Void)? = nil) {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {
            completion?()
        }
    }

    func unlockPrivate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on the phone, so there is nothing to check against.
            privateLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private tabs") { success, _ in
            DispatchQueue.main.async {
                if success { self.privateLocked = false }
            }
        }
    }
}
