import SwiftUI

struct BrowserScreen: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var store: TabStore

    @State private var address = ""
    @FocusState private var editing: Bool
    @State private var showVideos = false
    @State private var showTabs = false
    @State private var showDownloads = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ProgressView(value: tab.progress)
                .progressViewStyle(.linear)
                .tint(tab.isPrivate ? Color.purple : Color.accentColor)
                .opacity(tab.isLoading ? 1 : 0)

            if let insecure = tab.insecureOffer {
                insecureBanner(insecure)
            }

            ZStack {
                WebViewContainer(webView: tab.webView)
                if tab.savedURL == nil {
                    StartPage(isPrivate: tab.isPrivate)
                }
            }

            toolbar
        }
        .onAppear {
            tab.loadPendingIfNeeded()
            address = tab.savedURL?.absoluteString ?? ""
        }
        .onChange(of: tab.url) { _, newURL in
            if !editing { address = newURL?.absoluteString ?? "" }
        }
        .sheet(isPresented: $showVideos) { VideoListView(tab: tab) }
        .sheet(isPresented: $showTabs) { TabsView().environmentObject(store) }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.isPrivate ? "eye.slash.fill" : "lock.shield.fill")
                .foregroundStyle(tab.isPrivate ? Color.purple : Color.green)

            TextField(tab.isPrivate ? "Private search or address" : "Search or enter address", text: $address)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($editing)
                .onSubmit {
                    tab.load(input: address)
                    editing = false
                }

            if editing {
                Button("Cancel") {
                    editing = false
                    address = tab.url?.absoluteString ?? ""
                }
                .font(.subheadline)
            } else if tab.isLoading {
                Button { tab.webView.stopLoading() } label: { Image(systemName: "xmark") }
            } else if tab.url != nil {
                Button { tab.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tab.isPrivate ? Color.purple.opacity(0.15) : Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func insecureBanner(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(url.host ?? "This site") doesn't support a secure connection.")
                .font(.subheadline)
            HStack {
                Button("Load Anyway") { tab.allowInsecure() }
                Button("Dismiss") { tab.insecureOffer = nil }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
    }

    private var toolbar: some View {
        HStack {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.canGoBack)
            Spacer()
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward)
            Spacer()
            Button { showVideos = true } label: {
                Image(systemName: "arrow.down.circle")
                    .overlay(alignment: .topTrailing) {
                        if !tab.videos.isEmpty {
                            Text("\(tab.videos.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .disabled(tab.videos.isEmpty)
            Spacer()
            Button { showTabs = true } label: {
                Image(systemName: "square.on.square")
                    .overlay {
                        Text("\(store.tabs.count)").font(.system(size: 9, weight: .bold))
                    }
            }
            Spacer()
            Menu {
                Button { showDownloads = true } label: { Label("Downloads and Edits", systemImage: "tray.and.arrow.down") }
                Button { store.newTab(isPrivate: true) } label: { Label("New Private Tab", systemImage: "eye.slash") }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct StartPage: View {
    let isPrivate: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isPrivate ? "eye.slash.circle.fill" : "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(isPrivate ? Color.purple : Color.accentColor)
            Text(isPrivate ? "Private Tab" : "Veil").font(.largeTitle.bold())
            Text(isPrivate
                 ? "Cookies and site data from this tab are deleted when you close it."
                 : "Trackers are blocked and no history is kept.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
