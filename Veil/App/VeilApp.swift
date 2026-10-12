import SwiftUI
import UIKit

@main
struct VeilApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: TabStore

    init() {
        AppSettings.register()
        _ = DownloadManager.shared
        _store = StateObject(wrappedValue: TabStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletion[identifier] = completionHandler
    }
}
