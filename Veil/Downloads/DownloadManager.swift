import AVFoundation
import Foundation

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
}

/// Downloads plain video files with a background URLSession and HLS streams with
/// AVAssetDownloadURLSession, then converts streams to MP4. Finished files land in
/// Documents/Downloads, which shows up in the Files app under "On My iPhone > Veil".
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    static let fileSessionID = "com.veilbrowser.downloads.files"
    static let streamSessionID = "com.veilbrowser.downloads.streams"

    @Published private(set) var items: [DownloadItem] = []
    var backgroundCompletion: [String: () -> Void] = [:]

    private var pendingPackages: [UUID: URL] = [:]

    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        // Cookies are passed per request as a header and never stored by the session.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private lazy var streamSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.streamSessionID)
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        loadState()
        reconnect()
    }

    // MARK: Folders

    static var downloadsDir: URL { folder("Downloads") }
    static var editsDir: URL { folder("Edits") }

    private static func folder(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(name, isDirectory: true)
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
        if name.isEmpty { name = "video" }

        var candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    func fileURL(for item: DownloadItem) -> URL? {
        guard let name = item.fileName else { return nil }
        return Self.downloadsDir.appendingPathComponent(name)
    }

    // MARK: Starting and removing

    func start(_ video: DetectedVideo, headers: [String: String]) {
        let item = DownloadItem(
            id: UUID(), title: video.title, source: video.url,
            status: .downloading, progress: 0, fileName: nil, error: nil,
            isStream: video.isStream
        )
        items.insert(item, at: 0)
        save()

        if video.isStream {
            let asset = AVURLAsset(url: video.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            guard let task = streamSession.makeAssetDownloadTask(
                asset: asset, assetTitle: video.title, assetArtworkData: nil, options: nil
            ) else {
                fail(item.id, "This stream can't be downloaded.")
                return
            }
            task.taskDescription = item.id.uuidString
            task.resume()
        } else {
            var request = URLRequest(url: video.url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let task = fileSession.downloadTask(with: request)
            task.taskDescription = item.id.uuidString
            task.resume()
        }
    }

    func remove(_ item: DownloadItem) {
        let key = item.id.uuidString
        for session in [fileSession, streamSession as URLSession] {
            session.getAllTasks { tasks in
                tasks.filter { $0.taskDescription == key }.forEach { $0.cancel() }
            }
        }
        if let url = fileURL(for: item) { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: State

    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func itemID(_ task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap { UUID(uuidString: $0) }
    }

    private func fail(_ id: UUID, _ message: String) {
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
            if item.status == .converting {
                item.status = .failed
                item.error = "Interrupted. Try downloading again."
            }
            return item
        }
    }

    /// Reattaches to background sessions after launch and marks downloads that no longer exist.
    func reconnect() {
        let group = DispatchGroup()
        // A class box, because Swift won't let concurrent callbacks change a captured local var.
        final class LiveTasks { var ids = Set<String>() }
        let live = LiveTasks()
        for session in [fileSession, streamSession as URLSession] {
            group.enter()
            session.getAllTasks { tasks in
                let ids = tasks.compactMap { $0.taskDescription }
                DispatchQueue.main.async {
                    live.ids.formUnion(ids)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            for i in self.items.indices where self.items[i].status == .downloading
                && !live.ids.contains(self.items[i].id.uuidString) {
                self.items[i].status = .failed
                self.items[i].error = "Interrupted. Try downloading again."
            }
            self.save()
        }
    }

    // MARK: Stream conversion

    private func convert(_ id: UUID, package: URL) {
        guard let i = index(of: id) else { return }
        items[i].status = .converting
        items[i].progress = 0.95
        save()

        let asset = AVURLAsset(url: package)
        let dest = Self.uniqueURL(in: Self.downloadsDir, base: items[i].title, ext: "mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            fail(id, "Couldn't convert this stream.")
            return
        }
        export.outputURL = dest
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        // The manager is a singleton that lives for the whole app, so a strong capture is fine.
        export.exportAsynchronously {
            DispatchQueue.main.async {
                guard let i = self.index(of: id) else { return }
                if export.status == .completed {
                    self.items[i].status = .finished
                    self.items[i].progress = 1
                    self.items[i].fileName = dest.lastPathComponent
                    try? FileManager.default.removeItem(at: package)
                    self.save()
                } else {
                    self.fail(id, export.error?.localizedDescription ?? "Couldn't convert this stream.")
                }
            }
        }
    }

    private func fileExtension(response: URLResponse?, source: URL) -> String {
        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if ["mp4", "m4v", "mov", "webm"].contains(ext) { return ext }
        }
        let ext = source.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "webm"].contains(ext) { return ext }
        switch response?.mimeType ?? "" {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "mp4"
        }
    }
}

// MARK: - File downloads

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
            pendingPackages[id] = nil
            fail(id, error.localizedDescription)
            return
        }

        if session.configuration.identifier == Self.streamSessionID {
            if let package = pendingPackages.removeValue(forKey: id) {
                convert(id, package: package)
            } else {
                fail(id, "No video data was received.")
            }
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

// MARK: - Stream downloads

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected > 0, expected.isFinite,
              let id = itemID(assetDownloadTask), let i = index(of: id) else { return }
        let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
        items[i].progress = min(loaded / expected, 1) * 0.9
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = itemID(assetDownloadTask) else { return }
        pendingPackages[id] = location
    }
}
