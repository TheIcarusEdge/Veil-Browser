import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject private var store: TabStore
    @Environment(\.scenePhase) private var phase
    @AppStorage("lockPrivateTabs") private var lockPrivate = true
    @AppStorage("clearOnBackground") private var clearOnBackground = false
    @State private var obscured = false

    var body: some View {
        ZStack {
            if let tab = store.current {
                BrowserScreen(tab: tab).id(tab.id)
            }
            if let tab = store.current, tab.isPrivate, store.privateLocked || obscured {
                PrivateLockView(locked: store.privateLocked)
            }
        }
        // Videos shared to Veil from another app or opened from the Files app.
        .onOpenURL { url in store.open(fileFrom: url) }
        .sheet(item: $store.openedFile) { file in
            NavigationStack {
                EditorView(fileURL: file.url)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { store.openedFile = nil }
                        }
                    }
            }
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .inactive:
                // Hides private pages from the app switcher snapshot.
                obscured = true
            case .background:
                obscured = true
                if lockPrivate && store.hasPrivateTabs { store.privateLocked = true }
                if clearOnBackground { store.clearBrowsingData() }
                store.saveTabs()
            case .active:
                obscured = false
            @unknown default:
                break
            }
        }
    }
}

struct PrivateLockView: View {
    @EnvironmentObject private var store: TabStore
    let locked: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.purple)
                Text("Private Tabs Locked").font(.title3.bold())
                if locked {
                    Button("Unlock") { store.unlockPrivate() }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    Button("Go to a Normal Tab") { store.showNormalTab() }
                    Button("Close All Private Tabs", role: .destructive) { store.closeAllPrivate() }
                        .font(.footnote)
                }
            }
            .padding()
        }
    }
}

/// Hosts a tab's WKWebView, swapping it in when the tab changes.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        embed(in: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        if webView.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            embed(in: host)
        }
    }

    private func embed(in host: UIView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}
