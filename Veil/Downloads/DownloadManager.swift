import AVFoundation
import Foundation
import UIKit
import WebKit

struct DownloadItem: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case downloading, converting, finished, failed
    }

    let id: UUID
    var title: String
    var source: URL
    var status: Status
    var progress: Double
    var fileName: String?
    var error: String?
    var isStream: Bool
    /// True for non-video files (PDFs, documents, archives) saved from a page.
    var isFile: Bool?

    var isVideo: Bool {
        guard let name = fileName else { return isFile != true }
        return VideoFiles.isVideo(URL(fileURLWithPath: name))
    }
}

enum VideoFiles {
    static let extensions: Set<String> = ["mp4", "m4v", "mov", "webm", "3gp"]
    static func isVideo(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

/// Downloads plain video files with a background URLSession, HLS streams with Veil's own
/// stream downloader, and other files through WebKit. Finished files land in
/// Documents/Downloads, which shows up in the Files app under "On My iPhone > Veil".
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    static let fileSessionID = "com.veilbrowser.downloads.files"

    @Published private(set) var items: [DownloadItem] = []
    var backgroundCompletion: [String: () -> Void] = [:]

    private var streamJobs: [UUID: Task<Void, Never>] = [:]
    private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        // Cookies are passed per request as a header and never stored by the session.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        loadState()
        reconnect()
    }

    // MARK: Folders

    static var downloadsDir: URL { folder("Downloads") }
    static var editsDir: URL { folder("Edits") }
    static var importsDir: URL { folder("Imports") }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func folder(_ name: String) -> URL {
        let dir = documentsDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stateURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("downloads.json")
    }

    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var name = base.components(separatedBy: banned).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 60 { name = String(name.prefix(60)) }
        if name.isEmpty { name = "file" }

        func make(_ stem: String) -> URL {
            let url = dir.appendingPathComponent(stem)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var candidate = make(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(name) \(n)")
            n += 1
        }
        return candidate
    }

    func fileURL(for item: DownloadItem) -> URL? {
        guard let name = item.fileName else { return nil }
        return Self.downloadsDir.appendingPathComponent(name)
    }

    // MARK: Importing

    /// Copies a video from another app, the Files app or Photos into Documents/Imports.
    @discardableResult
    static func importFile(from url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let docs = documentsDir.standardizedFileURL.path
        let source = url.standardizedFileURL
        // Already inside Veil's own Imports folder: use it where it is.
        if source.path.hasPrefix(importsDir.standardizedFileURL.path) { return source }

        let dest = uniqueURL(
            in: importsDir,
            base: source.deletingPathExtension().lastPathComponent,
            ext: source.pathExtension.lowercased()
        )
        try FileManager.default.copyItem(at: source, to: dest)
        // Files handed over with "Copy to Veil" land in Documents/Inbox. Tidy them up.
        if source.path.hasPrefix(docs + "/Inbox") { try? FileManager.default.removeItem(at: source) }
        return dest
    }

    // MARK: Starting and Removing

    func start(_ video: DetectedVideo, cookies: [HTTPCookie], referer: URL?, userAgent: String?) {
        var headers: [String: String] = [:]
        if let referer { headers["Referer"] = referer.absoluteString }
        if let userAgent { headers["User-Agent"] = userAgent }

        let item = DownloadItem(
            id: UUID(), title: video.title, source: video.url,
            status: .downloading, progress: 0, fileName: nil, error: nil,
            isStream: video.isStream, isFile: false
        )
        items.insert(item, at: 0)
        save()

        if video.isStream {
            startStream(item, headers: headers, cookies: cookies)
            return
        }
        // Many players (Canvas and Kaltura among them) serve streams from links without
        // ".m3u8" in them. Check what the link really is before treating it as a file.
        let id = item.id
        let url = video.url
        Task.detached(priority: .userInitiated) {
            let playlist = await DownloadManager.isPlaylist(url, headers: headers, cookies: cookies)
            await MainActor.run {
                DownloadManager.shared.begin(id, asStream: playlist, headers: headers, cookies: cookies)
            }
        }
    }

    private func begin(_ id: UUID, asStream: Bool, headers: [String: String], cookies: [HTTPCookie]) {
        guard let i = index(of: id) else { return }  // removed while checking
        if asStream {
            items[i].isStream = true
            save()
            startStream(items[i], headers: headers, cookies: cookies)
            return
        }
        var request = URLRequest(url: items[i].source)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in CookieHeader.fields(for: items[i].source, from: cookies) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = fileSession.downloadTask(with: request)
        task.taskDescription = id.uuidString
        task.resume()
    }

    /// Reads the first bytes of a link to see whether it is an HLS playlist.
    private static func isPlaylist(_ url: URL, headers: [String: String], cookies: [HTTPCookie]) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in CookieHeader.fields(for: url, from: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        guard let result = try? await session.data(for: request) else { return false }
        let mime = (result.1.mimeType ?? "").lowercased()
        if mime.contains("mpegurl") { return true }
        return String(data: result.0.prefix(16), encoding: .utf8)?.hasPrefix("#EXTM3U") ?? false
    }

    private func startStream(_ item: DownloadItem, headers: [String: String], cookies: [HTTPCookie]) {
        let id = item.id
        let source = item.source
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-stream-\(id.uuidString)")

        // Streams download in the app, so ask iOS for extra time if Veil is put in the background.
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "Veil stream download") {
            DownloadManager.shared.endBackgroundTask(id)
        }

        streamJobs[id] = Task.detached(priority: .utility) {
            let downloader = HLSDownloader(
                source: source, headers: headers, cookies: cookies, workDir: workDir
            ) { fraction, finishing in
                DispatchQueue.main.async {
                    DownloadManager.shared.updateStream(id, progress: fraction, finishing: finishing)
                }
            }
            do {
                let produced = try await downloader.run()
                await MainActor.run { DownloadManager.shared.finishStream(id, file: produced, workDir: workDir) }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: workDir)
            } catch {
                let message = HLSDownloader.describe(error)
                try? FileManager.default.removeItem(at: workDir)
                await MainActor.run { DownloadManager.shared.fail(id, message) }
            }
            await MainActor.run { DownloadManager.shared.endBackgroundTask(id) }
        }
    }

    private func updateStream(_ id: UUID, progress: Double, finishing: Bool) {
        guard let i = index(of: id), items[i].status == .downloading || items[i].status == .converting else { return }
        items[i].progress = min(progress, 1) * 0.97
        if finishing { items[i].status = .converting }
    }

    private func finishStream(_ id: UUID, file: URL, workDir: URL) {
        streamJobs[id] = nil
        guard let i = index(of: id) else {
            try? FileManager.default.removeItem(at: workDir)
            return
        }
        let dest = Self.uniqueURL(in: Self.downloadsDir, base: items[i].title, ext: "mp4")
        do {
            try FileManager.default.moveItem(at: file, to: dest)
            items[i].fileName = dest.lastPathComponent
            items[i].status = .finished
            items[i].progress = 1
            items[i].error = nil
            save()
        } catch {
            fail(id, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: workDir)
    }

    private func endBackgroundTask(_ id: UUID) {
        if let task = backgroundTasks.removeValue(forKey: id), task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func remove(_ item: DownloadItem) {
        let key = item.id.uuidString
        fileSession.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == key }.forEach { $0.cancel() }
        }
        streamJobs.removeValue(forKey: item.id)?.cancel()
        WebDownload.cancel(item.id)
        endBackgroundTask(item.id)
        if let url = fileURL(for: item) { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: Files Saved by WebKit

    func addFileItem(_ id: UUID, title: String, source: URL?) {
        let item = DownloadItem(
            id: id, title: title, source: source ?? URL(string: "about:blank")!,
            status: .downloading, progress: 0, fileName: nil, error: nil,
            isStream: false, isFile: true
        )
        items.insert(item, at: 0)
        save()
    }

    func setProgress(_ id: UUID, _ value: Double) {
        guard let i = index(of: id), items[i].status == .downloading else { return }
        items[i].progress = value
    }

    func finishFile(_ id: UUID, file: URL?) {
        guard let i = index(of: id) else { return }
        guard let file, FileManager.default.fileExists(atPath: file.path) else {
            fail(id, "The file wasn't saved.")
            return
        }
        items[i].fileName = file.lastPathComponent
        items[i].status = .finished
        items[i].progress = 1
        save()
    }

    // MARK: State

    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func itemID(_ task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap { UUID(uuidString: $0) }
    }

    func fail(_ id: UUID, _ message: String) {
        streamJobs[id] = nil
        guard let i = index(of: id) else { return }
        items[i].status = .failed
        items[i].error = message
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = saved.map { item in
            var item = item
            if item.status == .converting || (item.status == .downloading && (item.isStream || item.isFile == true)) {
                item.status = .failed
                item.error = "Interrupted. Try downloading again."
            }
            return item
        }
    }

    /// Reattaches to the background session after launch and marks downloads that no longer exist.
    func reconnect() {
        fileSession.getAllTasks { tasks in
            let live = Set(tasks.compactMap { $0.taskDescription })
            DispatchQueue.main.async {
                let manager = DownloadManager.shared
                for i in manager.items.indices where manager.items[i].status == .downloading
                    && !manager.items[i].isStream && manager.items[i].isFile != true
                    && !live.contains(manager.items[i].id.uuidString) {
                    manager.items[i].status = .failed
                    manager.items[i].error = "Interrupted. Try downloading again."
                }
                manager.save()
            }
        }
    }

    private func fileExtension(response: URLResponse?, source: URL) -> String {
        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if VideoFiles.extensions.contains(ext) { return ext }
        }
        let ext = source.pathExtension.lowercased()
        if VideoFiles.extensions.contains(ext) { return ext }
        switch response?.mimeType ?? "" {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }
}

// MARK: - File Downloads

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let id = itemID(downloadTask), let i = index(of: id) else { return }
        items[i].progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = itemID(downloadTask), let i = index(of: id) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(id, "The site refused the download (error \(http.statusCode)).")
            return
        }

        let ext = fileExtension(response: downloadTask.response, source: items[i].source)
        let dest = Self.uniqueURL(in: Self.downloadsDir, base: items[i].title, ext: ext)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            items[i].fileName = dest.lastPathComponent
            items[i].status = .finished
            items[i].progress = 1
            save()
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = itemID(task), let i = index(of: id) else { return }
        if let error {
            fail(id, HLSDownloader.describe(error))
        } else if items[i].status == .downloading {
            fail(id, "The download ended without a file.")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        DispatchQueue.main.async {
            self.backgroundCompletion.removeValue(forKey: identifier)?()
        }
    }
}

// MARK: - WebKit Downloads

/// Saves a file a page offered for download (a PDF, a document, an attachment) into Documents/Downloads.
final class WebDownload: NSObject, WKDownloadDelegate {
    private static var active: [UUID: WebDownload] = [:]

    let id = UUID()
    private weak var download: WKDownload?
    private var destination: URL?
    private var observation: NSKeyValueObservation?

    static func begin(_ download: WKDownload) {
        let handler = WebDownload()
        handler.download = download
        download.delegate = handler
        active[handler.id] = handler
    }

    static func cancel(_ id: UUID) {
        guard let handler = active.removeValue(forKey: id) else { return }
        handler.download?.cancel { _ in }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let name = suggestedFilename as NSString
        let dest = DownloadManager.uniqueURL(
            in: DownloadManager.downloadsDir,
            base: name.deletingPathExtension,
            ext: name.pathExtension
        )
        destination = dest
        DownloadManager.shared.addFileItem(id, title: suggestedFilename, source: response.url)

        let id = self.id
        observation = download.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { DownloadManager.shared.setProgress(id, value) }
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DownloadManager.shared.finishFile(id, file: destination)
        Self.active[id] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DownloadManager.shared.fail(id, HLSDownloader.describe(error))
        Self.active[id] = nil
    }
}
