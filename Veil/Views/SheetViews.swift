import SwiftUI

// MARK: - Videos found on the current page

struct VideoListView: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @State private var started = Set<URL>()

    var body: some View {
        NavigationStack {
            List(tab.videos) { video in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).lineLimit(2)
                        Text(video.isStream ? "Stream from \(video.url.host ?? "")" : (video.url.host ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if started.contains(video.url) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button {
                            tab.download(video)
                            started.insert(video.url)
                        } label: {
                            Image(systemName: "arrow.down.circle").font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if tab.videos.isEmpty {
                    ContentUnavailableView(
                        "No Videos Found",
                        systemImage: "film",
                        description: Text("Start playing a video and it will show up here.")
                    )
                }
            }
            .navigationTitle("Videos on This Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Tabs

struct TabsView: View {
    @EnvironmentObject private var store: TabStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                tabSection("Tabs", tabs: store.tabs.filter { !$0.isPrivate })
                let privateTabs = store.tabs.filter { $0.isPrivate }
                if !privateTabs.isEmpty {
                    tabSection("Private Tabs", tabs: privateTabs)
                }
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        store.newTab(isPrivate: false)
                        dismiss()
                    } label: { Label("New Tab", systemImage: "plus") }
                    Spacer()
                    Button {
                        store.newTab(isPrivate: true)
                        dismiss()
                    } label: { Label("New Private Tab", systemImage: "eye.slash") }
                    .tint(.purple)
                }
            }
        }
    }

    private func tabSection(_ title: String, tabs: [BrowserTab]) -> some View {
        Section(title) {
            ForEach(tabs) { tab in
                TabRow(tab: tab, isCurrent: tab.id == store.current?.id, hidden: tab.isPrivate && store.privateLocked)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.select(tab)
                        dismiss()
                    }
            }
            .onDelete { offsets in
                offsets.map { tabs[$0] }.forEach(store.close)
            }
        }
    }
}

struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let isCurrent: Bool
    let hidden: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(hidden ? "Locked" : tab.title).lineLimit(1)
                Text(hidden ? " " : (tab.savedURL?.host ?? "Start Page"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var store: TabStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("searchEngine") private var engine = SearchEngine.duckDuckGo.rawValue
    @AppStorage("blockTrackers") private var blockTrackers = true
    @AppStorage("httpsOnly") private var httpsOnly = true
    @AppStorage("lockPrivateTabs") private var lockPrivate = true
    @AppStorage("clearOnBackground") private var clearOnBackground = false
    @AppStorage("restoreTabs") private var restoreTabs = true
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    Picker("Search Engine", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }

                Section {
                    Toggle("Reopen Tabs on Launch", isOn: $restoreTabs)
                        .onChange(of: restoreTabs) { _, on in
                            if on { store.saveTabs() } else { store.forgetSavedTabs() }
                        }
                } header: {
                    Text("Tabs")
                } footer: {
                    Text("Normal tabs come back when you reopen Veil. Private tabs are never saved.")
                }

                Section {
                    Toggle("Block Trackers and Ads", isOn: $blockTrackers)
                        .onChange(of: blockTrackers) { _, _ in store.applyBlocking() }
                    Toggle("HTTPS Only", isOn: $httpsOnly)
                    Toggle("Lock Private Tabs", isOn: $lockPrivate)
                    Toggle("Clear Data When Leaving App", isOn: $clearOnBackground)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Private tabs never save cookies or site data. Veil keeps no browsing history, only the open tabs if Reopen Tabs on Launch is on.")
                }

                Section {
                    Button(cleared ? "Cleared" : "Clear Cookies and Site Data", role: .destructive) {
                        store.clearBrowsingData { cleared = true }
                    }
                    .disabled(cleared)
                }

                Section("About") {
                    LabeledContent(
                        "Version",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    )
                    Text("No analytics and no accounts. Veil only talks to the sites you visit and your chosen search engine.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
