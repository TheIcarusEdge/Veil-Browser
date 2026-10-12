import Foundation

/// A problem with a stream download, worded for the person using the app.
struct DownloadFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ByteRange: Equatable {
    let length: Int
    let offset: Int
    var httpHeader: String { "bytes=\(offset)-\(offset + length - 1)" }
}

struct HLSKey: Equatable {
    let uri: URL
    let iv: Data?
}

struct HLSSegment {
    let url: URL
    let range: ByteRange?
    let key: HLSKey?
    let sequence: Int
    let discontinuity: Bool
}

struct HLSMediaPlaylist {
    var segments: [HLSSegment] = []
    var initSegment: (url: URL, range: ByteRange?)?
    var isComplete = false
}

struct HLSVariant {
    let url: URL
    let bandwidth: Int
    let codecs: String
    let audioGroup: String?
}

struct HLSRendition {
    let groupID: String
    let url: URL
    let isDefault: Bool
}

struct HLSMasterPlaylist {
    var variants: [HLSVariant] = []
    var audio: [HLSRendition] = []

    /// The best quality variant Veil can save. Streams in TS format must be H.264,
    /// so H.264 variants are preferred when the codecs are listed.
    func bestVariant() -> HLSVariant? {
        let avc = variants.filter { $0.codecs.isEmpty || $0.codecs.contains("avc1") }
        let pool = avc.isEmpty ? variants : avc
        return pool.max { $0.bandwidth < $1.bandwidth }
    }

    func audioRendition(for variant: HLSVariant) -> HLSRendition? {
        guard let group = variant.audioGroup else { return nil }
        let matches = audio.filter { $0.groupID == group }
        return matches.first { $0.isDefault } ?? matches.first
    }
}

/// Reads HLS playlists (.m3u8).
enum HLSParser {
    static func isMaster(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    static func parseMaster(_ text: String, base: URL) throws -> HLSMasterPlaylist {
        var result = HLSMasterPlaylist()
        var pendingInfo: [String: String]?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                try rejectDRM(attributes(after: line))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingInfo = attributes(after: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(after: line)
                if attrs["TYPE"] == "AUDIO", let uri = attrs["URI"], let group = attrs["GROUP-ID"],
                   let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    result.audio.append(HLSRendition(groupID: group, url: url, isDefault: attrs["DEFAULT"] == "YES"))
                }
            } else if !line.hasPrefix("#"), let info = pendingInfo {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    result.variants.append(HLSVariant(
                        url: url,
                        bandwidth: Int(info["BANDWIDTH"] ?? "") ?? 0,
                        codecs: info["CODECS"] ?? "",
                        audioGroup: info["AUDIO"]
                    ))
                }
                pendingInfo = nil
            }
        }
        return result
    }

    static func parseMedia(_ text: String, base: URL) throws -> HLSMediaPlaylist {
        var result = HLSMediaPlaylist()
        var sequence = 0
        var key: HLSKey?
        var range: ByteRange?
        var discontinuity = false
        var lastRangeEnd: [URL: Int] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(after: line)
                try rejectDRM(attrs)
                switch attrs["METHOD"] ?? "NONE" {
                case "NONE":
                    key = nil
                case "AES-128":
                    guard let uri = attrs["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else {
                        throw DownloadFailure("The stream's encryption key is missing.")
                    }
                    key = HLSKey(uri: url, iv: attrs["IV"].flatMap(hexData))
                default:
                    throw DownloadFailure("This video is protected (DRM), so it can't be downloaded.")
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(after: line)
                if result.initSegment == nil, let uri = attrs["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    let mapRange = attrs["BYTERANGE"].flatMap { parseRange($0, previousEnd: 0) }
                    result.initSegment = (url, mapRange)
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                range = parseRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), previousEnd: nil)
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuity = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                result.isComplete = true
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                var segmentRange = range
                // A byte range without an offset starts where the last range of the same file ended.
                if let r = range, r.offset < 0 {
                    segmentRange = ByteRange(length: r.length, offset: lastRangeEnd[url] ?? 0)
                }
                if let r = segmentRange { lastRangeEnd[url] = r.offset + r.length }
                result.segments.append(HLSSegment(
                    url: url, range: segmentRange, key: key, sequence: sequence, discontinuity: discontinuity
                ))
                sequence += 1
                range = nil
                discontinuity = false
            }
        }
        return result
    }

    // MARK: Helpers

    private static func rejectDRM(_ attrs: [String: String]) throws {
        let method = attrs["METHOD"] ?? "NONE"
        let format = attrs["KEYFORMAT"] ?? "identity"
        if method.hasPrefix("SAMPLE-AES") || format != "identity" {
            throw DownloadFailure("This video is protected (DRM), so it can't be downloaded.")
        }
    }

    /// "1234@5678" or "1234". A missing offset is stored as -1 and filled in by the caller.
    private static func parseRange(_ text: String, previousEnd: Int?) -> ByteRange? {
        let parts = text.split(separator: "@")
        guard let length = Int(parts.first ?? "") else { return nil }
        if parts.count > 1, let offset = Int(parts[1]) { return ByteRange(length: length, offset: offset) }
        return ByteRange(length: length, offset: previousEnd ?? -1)
    }

    private static func hexData(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 16 ? data : nil
    }

    /// Reads an attribute list like `BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2"`.
    static func attributes(after line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let text = line[line.index(after: colon)...]
        var result: [String: String] = [:]
        var i = text.startIndex

        while i < text.endIndex {
            guard let eq = text[i...].firstIndex(of: "=") else { break }
            let key = text[i..<eq].trimmingCharacters(in: .whitespaces)
            var j = text.index(after: eq)
            var value = ""
            if j < text.endIndex, text[j] == "\"" {
                let start = text.index(after: j)
                let close = text[start...].firstIndex(of: "\"") ?? text.endIndex
                value = String(text[start..<close])
                j = close < text.endIndex ? text.index(after: close) : close
            } else {
                let end = text[j...].firstIndex(of: ",") ?? text.endIndex
                value = String(text[j..<end])
                j = end
            }
            result[key] = value
            if j < text.endIndex, text[j] == "," { j = text.index(after: j) }
            i = j
        }
        return result
    }
}
