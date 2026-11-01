import Foundation

struct GlassMediaItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    let mimeType: String
    let size: Int64
    let modifiedTimeMs: Int64
    let revision: String

    var isVideo: Bool { kind == "Video" }
    var date: Date { Date(timeIntervalSince1970: Double(modifiedTimeMs) / 1000) }
    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var cacheKey: String { "\(id)-\(revision)" }
    var fileExtension: String {
        switch mimeType {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "video/3gpp": return "3gp"
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        default: return isVideo ? "mp4" : "jpg"
        }
    }
}

struct GlassMediaRequest: Encodable {
    var requestId = UUID().uuidString
    let operation: String
    var mediaId: String?
    var revision: String?
    var beforeId: String?
    var pageSize = 48
    var offset: Int64 = 0
    var length = 96 * 1024
}

struct GlassMediaReply: Decodable {
    let requestId: String
    let operation: String
    let mediaId: String?
    let error: String?
    let items: [GlassMediaItem]?
    let hasMore: Bool
    let nextBeforeId: String?
    let data: Data?
    let offset: Int64
    let totalBytes: Int64
}

enum GalleryError: LocalizedError {
    case disconnected, timeout, invalidReply, remote(String), photosPermission, fileTooLarge
    var errorDescription: String? {
        switch self {
        case .disconnected: return "Connect and approve Glass to browse its media library. Downloaded items are still available offline."
        case .timeout: return "Glass did not answer the gallery request. Install the updated Explorer APK from this project, then reconnect and try again."
        case .invalidReply: return "The media transfer was incomplete or changed on Glass. Refresh the gallery and try again."
        case .remote(let message): return message
        case .photosPermission: return "Allow Add Photos access in iPhone Settings to save this item to Photos. You can still use Share to save it to Files."
        case .fileTooLarge: return "This item is larger than the current 2 GB download limit."
        }
    }
}
