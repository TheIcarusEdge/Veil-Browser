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
    @State private var showHistory = false

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
        .sheet(isPresented: $showHistory) { HistoryView(tab: tab) }
        .sheet(item: $tab.pickedVideo) { picked in
            PickedVideoSheet(tab: tab, picked: picked) { showVideos = true }
                .presentationDetents([.medium])
        }
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
            Button {
                tab.captureSnapshot()
                showTabs = true
            } label: {
                Image(systemName: "square.on.square")
                    .overlay {
                        Text("\(store.tabs.count)").font(.system(size: 9, weight: .bold))
                    }
            }
            Spacer()
            Menu {
                // New tabs match the mode you're in. The second button switches modes.
                Button { store.newTab(isPrivate: tab.isPrivate) } label: {
                    Label(tab.isPrivate ? "New Private Tab" : "New Tab", systemImage: "plus.square.on.square")
                }
                Button { store.newTab(isPrivate: !tab.isPrivate) } label: {
                    Label(tab.isPrivate ? "New Normal Tab" : "New Private Tab", systemImage: tab.isPrivate ? "eye" : "eye.slash")
                }
                Divider()
                Button { showDownloads = true } label: { Label("Downloads and Edits", systemImage: "tray.and.arrow.down") }
                Button { showHistory = true } label: { Label("History", systemImage: "clock") }
                if tab.url != nil, AppSettings.blockTrackers {
                    Button { tab.toggleBlockingHere() } label: {
                        if tab.isBlockingOffHere {
                            Label("Turn On Ad Blocking Here", systemImage: "shield.lefthalf.filled")
                        } else {
                            Label("Turn Off Ad Blocking Here", systemImage: "shield.slash")
                        }
                    }
                }
                Divider()
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
            if isPrivate {
                Image(systemName: "eye.slash.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.purple)
            } else {
                Image("VeilMark")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            Text(isPrivate ? "Private Tab" : "Veil").font(.largeTitle.bold())
            Text(isPrivate
                 ? "Cookies and site data from this tab are deleted when you close it."
                 : "Ads and trackers are blocked. History is off unless you turn it on.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Long-Pressed Video

struct PickedVideoSheet: View {
    @ObservedObject var tab: BrowserTab
    let picked: PickedVideo
    let showFound: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(picked.title.isEmpty ? "Video" : picked.title).font(.headline)
                    if picked.isHidden {
                        Text("This player hides the video file, so Veil can't save it from here. If the video has started playing, check Videos on This Page for a stream copy.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if !picked.address.isEmpty {
                    Section("Video Source") {
                        Text(picked.address)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(6)
                        Button(copied ? "Copied" : "Copy Video Address") {
                            UIPasteboard.general.string = picked.address
                            copied = true
                        }
                    }
                }

                Section {
                    if picked.url != nil {
                        Button {
                            tab.download(picked)
                            dismiss()
                        } label: {
                            Label("Download This Video", systemImage: "arrow.down.circle")
                        }
                    }
                    if !tab.videos.isEmpty {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showFound() }
                        } label: {
                            Label("Videos on This Page (\(tab.videos.count))", systemImage: "film.stack")
                        }
                    }
                }
            }
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
