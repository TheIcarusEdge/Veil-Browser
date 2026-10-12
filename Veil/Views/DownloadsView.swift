import AVKit
import CoreTransferable
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A video passed in from Photos or dropped onto Veil. Copied into Documents/Imports.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            ImportedMovie(url: try DownloadManager.importFile(from: received.file))
        }
    }
}

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var edits: [URL] = []
    @State private var imports: [URL] = []
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var openFile: URL?
    @State private var preview: URL?
    @State private var importError: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Downloads") {
                    if manager.items.isEmpty {
                        Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(manager.items) { item in
                        DownloadRow(item: item) { preview = $0 }
                    }
                    .onDelete { offsets in
                        offsets.map { manager.items[$0] }.forEach(manager.remove)
                    }
                }

                Section {
                    if imports.isEmpty {
                        Text("Add a video from Files or Photos with the plus button, or share one to Veil from another app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(imports, id: \.self) { url in
                        NavigationLink {
                            EditorView(fileURL: url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? FileManager.default.removeItem(at: imports[i]) }
                        loadFiles()
                    }
                } header: {
                    Text("Imported")
                } footer: {
                    if importing {
                        Text("Importing...")
                    } else if let importError {
                        Text(importError).foregroundStyle(.red)
                    }
                }

                if !edits.isEmpty {
                    Section("Edits") {
                        ForEach(edits, id: \.self) { url in
                            NavigationLink {
                                EditorView(fileURL: url)
                            } label: {
                                Label(url.lastPathComponent, systemImage: "film")
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { try? FileManager.default.removeItem(at: edits[i]) }
                            loadFiles()
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showFilePicker = true } label: { Label("Import From Files", systemImage: "folder") }
                        Button { showPhotoPicker = true } label: { Label("Import From Photos", systemImage: "photo.on.rectangle") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: loadFiles)
            .onChange(of: manager.items) { _, _ in loadFiles() }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.movie, .video, .audiovisualContent],
                allowsMultipleSelection: true
            ) { result in
                importFiles(result)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .videos)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                importPhotos(items)
            }
            .dropDestination(for: ImportedMovie.self) { movies, _ in
                loadFiles()
                if let first = movies.first { openFile = first.url }
                return !movies.isEmpty
            }
            .navigationDestination(item: $openFile) { url in
                EditorView(fileURL: url)
            }
            .quickLookPreview($preview)
        }
    }

    private func loadFiles() {
        edits = Self.videos(in: DownloadManager.editsDir)
        // Imports, plus any video someone dropped straight into Veil's folder in the Files app.
        imports = Self.videos(in: DownloadManager.importsDir) + Self.videos(in: DownloadManager.documentsDir)
    }

    private static func videos(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { VideoFiles.isVideo($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            var last: URL?
            for url in urls {
                do { last = try DownloadManager.importFile(from: url) } catch { importError = error.localizedDescription }
            }
            loadFiles()
            if urls.count == 1, let last { openFile = last }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        importing = true
        importError = nil
        Task {
            var last: URL?
            for item in items {
                do {
                    if let movie = try await item.loadTransferable(type: ImportedMovie.self) { last = movie.url }
                } catch {
                    importError = "Couldn't import from Photos. \(error.localizedDescription)"
                }
            }
            importing = false
            photoItems = []
            loadFiles()
            if items.count == 1, let last { openFile = last }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let preview: (URL) -> Void

    var body: some View {
        if item.status == .finished, let url = DownloadManager.shared.fileURL(for: item) {
            if item.isVideo {
                NavigationLink { EditorView(fileURL: url) } label: { details }
            } else {
                Button { preview(url) } label: { details }
                    .foregroundStyle(.primary)
            }
        } else {
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(item.title).lineLimit(2)
            } icon: {
                Image(systemName: item.isFile == true ? "doc" : (item.isStream ? "dot.radiowaves.left.and.right" : "film"))
                    .foregroundStyle(.secondary)
            }
            switch item.status {
            case .downloading:
                ProgressView(value: item.progress)
            case .converting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Building MP4").font(.caption).foregroundStyle(.secondary)
                }
            case .finished:
                Text(item.fileName ?? "").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Text(item.error ?? "Failed").font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Lets the person pick a folder in the Files app to save a copy into.
struct SaveToFiles: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - Editor

struct EditorView: View {
    let fileURL: URL

    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var muted = false
    @State private var speed: Double = 1
    @State private var crop: CropAspect = .off
    @State private var cropPosition: Double = 0.5
    @State private var displaySize: CGSize = .zero
    @State private var exporting = false
    @State private var exported: URL?
    @State private var message: String?
    @State private var saveTarget: OpenedFile?

    init(fileURL: URL) {
        self.fileURL = fileURL
        _player = State(initialValue: AVPlayer(url: fileURL))
    }

    private var upperBound: Double { max(duration, 0.1) }

    var body: some View {
        Form {
            Section {
                VideoPlayer(player: player)
                    .overlay {
                        CropOverlay(display: displaySize, aspect: crop, position: cropPosition)
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
            }

            Section("Trim") {
                LabeledContent("Start", value: format(start))
                Slider(value: $start, in: 0...upperBound, onEditingChanged: { isEditing in
                    if !isEditing { seek(start) }
                })
                LabeledContent("End", value: format(end))
                Slider(value: $end, in: 0...upperBound, onEditingChanged: { isEditing in
                    if !isEditing { seek(end) }
                })
                LabeledContent("Final Length", value: format(max(end - start, 0) / speed))
            }

            Section("Crop") {
                Picker("Shape", selection: $crop) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if crop != .off {
                    let horizontal = VideoExporter.cropSlidesHorizontally(display: displaySize, aspect: crop)
                    Slider(value: $cropPosition, in: 0...1) {
                        Text("Position")
                    } minimumValueLabel: {
                        Text(horizontal ? "Left" : "Top").font(.caption)
                    } maximumValueLabel: {
                        Text(horizontal ? "Right" : "Bottom").font(.caption)
                    }
                    Button("Center") { cropPosition = 0.5 }
                        .disabled(cropPosition == 0.5)
                }

                LabeledContent("Output Size", value: outputSizeText)
            }

            Section("Options") {
                Toggle("Remove Audio", isOn: $muted)
                Picker("Speed", selection: $speed) {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                        Text("\(value.formatted())x").tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button(exporting ? "Exporting..." : "Export Clip") {
                    Task { await runExport() }
                }
                .disabled(exporting || end - start < 0.5)

                if let exported {
                    ShareLink(item: exported) { Label("Share Clip", systemImage: "square.and.arrow.up") }
                    Button { saveToPhotos(exported) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                    Button { saveTarget = OpenedFile(url: exported) } label: { Label("Save Clip to Files", systemImage: "folder") }
                }
                ShareLink(item: fileURL) { Label("Share Original", systemImage: "square.and.arrow.up.on.square") }
                Button { saveTarget = OpenedFile(url: fileURL) } label: { Label("Save Original to Files", systemImage: "folder.badge.plus") }
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(fileURL.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let asset = AVURLAsset(url: fileURL)
            if let length = try? await asset.load(.duration), length.seconds.isFinite {
                duration = length.seconds
                end = length.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await VideoExporter.displaySize(of: track) {
                displaySize = size
            }
        }
        .onChange(of: start) { _, value in if value > end { end = value } }
        .onChange(of: end) { _, value in if value < start { start = value } }
        .onDisappear { player.pause() }
        .sheet(item: $saveTarget) { file in SaveToFiles(url: file.url) }
    }

    private var outputSizeText: String {
        guard displaySize.width > 0 else { return "Unknown" }
        let rect = VideoExporter.cropRect(display: displaySize, aspect: crop, position: cropPosition)
        return "\(Int(rect.width)) x \(Int(rect.height))"
    }

    private func seek(_ seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func format(_ seconds: Double) -> String {
        let safe = max(seconds, 0)
        return String(format: "%ld:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }

    private func runExport() async {
        exporting = true
        message = nil
        do {
            exported = try await VideoExporter.export(
                source: fileURL, start: start, end: min(end, duration), muted: muted, speed: speed,
                crop: crop, cropPosition: cropPosition
            )
            message = "Saved to Files under Veil > Edits."
        } catch {
            message = error.localizedDescription
        }
        exporting = false
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "Allow photo access in Settings to save clips." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                DispatchQueue.main.async {
                    message = success ? "Saved to Photos." : (error?.localizedDescription ?? "Couldn't save to Photos.")
                }
            }
        }
    }
}

// MARK: - Crop Preview

/// Dims the parts of the video that the crop will cut off and outlines the part that stays.
/// It ignores touches so the player controls underneath still work.
struct CropOverlay: View {
    let display: CGSize
    let aspect: CropAspect
    let position: Double

    var body: some View {
        GeometryReader { geo in
            if aspect != .off, display.width > 0, display.height > 0 {
                let frame = fittedFrame(in: geo.size)
                let scale = frame.width / display.width
                let keep = VideoExporter.cropRect(display: display, aspect: aspect, position: position)
                let shown = CGRect(
                    x: frame.minX + keep.minX * scale,
                    y: frame.minY + keep.minY * scale,
                    width: keep.width * scale,
                    height: keep.height * scale
                )

                Path { path in
                    path.addRect(frame)
                    path.addRect(shown)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                Rectangle()
                    .path(in: shown)
                    .stroke(Color.white, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the video sits inside the player, which fits it to the space and centers it.
    private func fittedFrame(in container: CGSize) -> CGRect {
        let scale = min(container.width / display.width, container.height / display.height)
        let size = CGSize(width: display.width * scale, height: display.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
