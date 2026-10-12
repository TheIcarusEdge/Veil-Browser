import SwiftUI

// MARK: - Videos Found on the Current Page

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
                        Text(video.url.absoluteString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = video.url.absoluteString
                    } label: {
                        Label("Copy Video Address", systemImage: "doc.on.doc")
                    }
                    Button {
                        tab.download(video)
                        started.insert(video.url)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
            .overlay {
                if tab.videos.isEmpty {
                    ContentUnavailableView(
                        "No Videos Found",
                        systemImage: "film",
                        description: Text("Start playing a video and it will show up here. You can also press and hold a video on the page.")
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

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                let normal = store.tabs.filter { !$0.isPrivate }
                let privateTabs = store.tabs.filter { $0.isPrivate }

                tabGrid(normal)

                if !privateTabs.isEmpty {
                    HStack {
                        Label("Private Tabs", systemImage: "eye.slash")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    tabGrid(privateTabs)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(store.tabs.count) \(store.tabs.count == 1 ? "Tab" : "Tabs")")
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

    private func tabGrid(_ tabs: [BrowserTab]) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(tabs) { tab in
                TabCard(
                    tab: tab,
                    isCurrent: tab.id == store.current?.id,
                    hidden: tab.isPrivate && store.privateLocked,
                    close: { withAnimation { store.close(tab) } }
                )
                .onTapGesture {
                    store.select(tab)
                    dismiss()
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

/// A tab in the switcher: a picture of the page with its title underneath.
struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isCurrent: Bool
    let hidden: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isCurrent ? (tab.isPrivate ? Color.purple : Color.accentColor) : Color.secondary.opacity(0.25),
                                lineWidth: isCurrent ? 3 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

            Text(hidden ? "Locked" : tab.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        if hidden {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Image(systemName: "lock.fill").font(.title).foregroundStyle(.purple)
            }
        } else if let image = tab.snapshot {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ZStack {
                Rectangle().fill(Color(.secondarySystemBackground))
                VStack(spacing: 8) {
                    Image(systemName: tab.isPrivate ? "eye.slash" : "globe")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(tab.savedURL?.host ?? "Start Page")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveHistory") private var saveHistory = false
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    private struct Day: Identifiable {
        let day: Date
        let entries: [HistoryEntry]
        var id: Date { day }
    }

    /// Entries grouped by day, newest first.
    private var days: [Day] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { Day(day: $0, entries: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(group.entries) { entry in
                            Button {
                                tab.load(entry.url)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(1).foregroundStyle(.primary)
                                    Text(entry.url.host ?? entry.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { history.delete(entry) }
                            }
                        }
                    }
                }
            }
            .overlay {
                if !saveHistory && history.entries.isEmpty {
                    ContentUnavailableView {
                        Label("History Is Off", systemImage: "clock.badge.xmark")
                    } description: {
                        Text("Veil doesn't keep a record of the pages you visit. Turn on history to keep one for normal tabs. Private tabs are never recorded.")
                    } actions: {
                        Button("Turn On History") { saveHistory = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search History")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(history.entries.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { history.clear() }
            }
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
    @AppStorage("saveHistory") private var saveHistory = false
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
                    Toggle("Save History", isOn: $saveHistory)
                        .onChange(of: saveHistory) { _, on in
                            if !on { HistoryStore.shared.clear() }
                        }
                } header: {
                    Text("Tabs and History")
                } footer: {
                    Text("Normal tabs come back when you reopen Veil. History covers normal tabs only, and turning it off deletes it. Private tabs are never saved.")
                }

                Section {
                    Toggle("Block Ads and Trackers", isOn: $blockTrackers)
                        .onChange(of: blockTrackers) { _, _ in store.applyBlocking() }
                    NavigationLink("Sites With Blocking Off") { BlockingExceptionsView() }
                } header: {
                    Text("Ad Blocking")
                } footer: {
                    Text("Blocks about 6,500 ad and tracking networks. If a site breaks, open the menu and choose Turn Off Ad Blocking Here.")
                }

                Section {
                    Toggle("HTTPS Only", isOn: $httpsOnly)
                    Toggle("Lock Private Tabs", isOn: $lockPrivate)
                    Toggle("Clear Data When Leaving App", isOn: $clearOnBackground)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Private tabs never save cookies or site data.")
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

struct BlockingExceptionsView: View {
    @EnvironmentObject private var store: TabStore
    @State private var hosts: [String] = AppSettings.blockingOffHosts.sorted()

    var body: some View {
        List {
            ForEach(hosts, id: \.self) { host in
                Text(host)
            }
            .onDelete { offsets in
                for i in offsets { AppSettings.setBlockingOff(false, for: hosts[i]) }
                hosts = AppSettings.blockingOffHosts.sorted()
                store.applyBlocking()
            }
        }
        .overlay {
            if hosts.isEmpty {
                ContentUnavailableView(
                    "No Exceptions",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("Ad blocking is on for every site.")
                )
            }
        }
        .navigationTitle("Sites With Blocking Off")
        .navigationBarTitleDisplayMode(.inline)
    }
}
