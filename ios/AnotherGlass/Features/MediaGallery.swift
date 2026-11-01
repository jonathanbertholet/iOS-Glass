import Combine
import Foundation
import UIKit

@MainActor
final class MediaGallery: ObservableObject {
    @Published private(set) var items: [GlassMediaItem] = []
    @Published private(set) var downloads: [DownloadedMedia] = []
    @Published private(set) var connected = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var needsRefresh = true
    @Published private(set) var downloadingID: String?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var sessionDownloads: [String: DownloadedMedia] = [:]
    @Published var error: String?

    private weak var server: GlassServer?
    private var cursor: String?
    private var session = UUID()
    private var transfer: Task<Void, Never>?
    private var loadingToken: UUID?
    private var libraryChanges = 0
    private let thumbnails = NSCache<NSString, NSData>()
    private struct Pending {
        let request: GlassMediaRequest
        let continuation: CheckedContinuation<GlassMediaReply, Error>
    }
    private var pending: [String: Pending] = [:]
    private var queue: [String] = []
    private var active: String?
    private var timeout: Task<Void, Never>?

    init(server: GlassServer) {
        self.server = server
        thumbnails.totalCostLimit = 8 * 1024 * 1024
        thumbnails.countLimit = 100
        Task {
            do { downloads = try await Task.detached(priority: .utility) { try MediaFiles.load() }.value }
            catch { self.error = "Downloaded media could not be loaded: \(error.localizedDescription)" }
        }
    }

    func setConnected(_ value: Bool) {
        connected = value
        session = UUID()
        transfer?.cancel()
        failPending(with: GalleryError.disconnected)
        items = []
        cursor = nil
        hasMore = false
        isLoading = false
        loadingToken = nil
        sessionDownloads = [:]
        thumbnails.removeAllObjects()
        error = nil
        needsRefresh = true
    }

    func refresh() async { await load(reset: true) }
    func loadMore() async { if hasMore { await load(reset: false) } }

    private func load(reset: Bool) async {
        guard connected, !isLoading else { return }
        let token = UUID()
        let currentSession = session
        let changeCount = libraryChanges
        loadingToken = token
        isLoading = true
        error = nil
        defer {
            if loadingToken == token { isLoading = false; loadingToken = nil }
        }
        do {
            var message = GlassMediaRequest(operation: "List")
            message.beforeId = reset ? nil : cursor
            let reply = try await request(message)
            try Task.checkCancellation()
            guard currentSession == session else { return }
            guard let page = reply.items,
                  page.count <= 48,
                  page.allSatisfy({ ($0.kind == "Photo" || $0.kind == "Video") && $0.size > 0 && !$0.id.isEmpty }),
                  !reply.hasMore || (reply.nextBeforeId != nil && reply.nextBeforeId != message.beforeId) else {
                throw GalleryError.invalidReply
            }
            var seen = Set<String>()
            items = ((reset ? [] : items) + page).filter { seen.insert($0.id).inserted }
            hasMore = reply.hasMore
            cursor = reply.nextBeforeId
            needsRefresh = changeCount != libraryChanges
        } catch is CancellationError { }
        catch {
            if currentSession == session {
                self.error = error.localizedDescription
                needsRefresh = false // Retry by user action or a new library-change event.
            }
        }
    }

    func thumbnail(for item: GlassMediaItem) async throws -> UIImage? {
        let bytes = try await thumbnailBytes(for: item)
        return await MediaImages.thumbnail(data: bytes, pixels: 400)
    }

    private func thumbnailBytes(for item: GlassMediaItem) async throws -> Data {
        if let bytes = thumbnails.object(forKey: item.cacheKey as NSString) { return bytes as Data }
        let currentSession = session
        let message = GlassMediaRequest(operation: "Thumbnail", mediaId: item.id, revision: item.revision)
        let reply = try await request(message)
        try Task.checkCancellation()
        guard currentSession == session, let bytes = reply.data, !bytes.isEmpty, bytes.count <= 160 * 1024 else {
            throw GalleryError.invalidReply
        }
        thumbnails.setObject(bytes as NSData, forKey: item.cacheKey as NSString, cost: bytes.count)
        return bytes
    }

    func download(_ item: GlassMediaItem) {
        guard transfer == nil else { error = "A download is already in progress."; return }
        guard connected else { error = GalleryError.disconnected.localizedDescription; return }
        guard item.size <= 2 * 1024 * 1024 * 1024 else { error = GalleryError.fileTooLarge.localizedDescription; return }
        downloadingID = item.id
        downloadProgress = 0
        error = nil
        let currentSession = session
        transfer = Task {
            var writer: MediaFileWriter?
            defer { transfer = nil; downloadingID = nil }
            do {
                let thumbnail = try? await thumbnailBytes(for: item)
                try Task.checkCancellation()
                let file = try MediaFileWriter()
                writer = file
                var offset: Int64 = 0
                while offset < item.size {
                    try Task.checkCancellation()
                    let count = Int(min(96 * 1024, item.size - offset))
                    let message = GlassMediaRequest(operation: "Read", mediaId: item.id,
                                                   revision: item.revision, offset: offset, length: count)
                    let reply = try await request(message)
                    try Task.checkCancellation()
                    guard currentSession == session, reply.offset == offset, reply.totalBytes == item.size,
                          let bytes = reply.data, bytes.count == count else { throw GalleryError.invalidReply }
                    try await file.append(bytes)
                    offset += Int64(bytes.count)
                    downloadProgress = Double(offset) / Double(item.size)
                }
                try Task.checkCancellation()
                let saved = DownloadedMedia(id: UUID(), original: item, downloadedAt: Date())
                try await file.finish(saved, thumbnail: thumbnail)
                downloads.insert(saved, at: 0)
                if currentSession == session { sessionDownloads[item.cacheKey] = saved }
            } catch is CancellationError {
                if let writer { await writer.discard() }
            } catch {
                if let writer { await writer.discard() }
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelDownload() { transfer?.cancel() }

    func receive(_ message: IncomingMessage) {
        do {
            let reply = try message.decodePayload(GlassMediaReply.self)
            if reply.operation == "Changed" {
                libraryChanges += 1
                needsRefresh = true
                return
            }
            guard let waiting = pending[reply.requestId] else { return }
            guard reply.operation == waiting.request.operation, reply.mediaId == waiting.request.mediaId else {
                finish(reply.requestId, result: .failure(GalleryError.invalidReply)); return
            }
            if let error = reply.error { finish(reply.requestId, result: .failure(GalleryError.remote(error))) }
            else { finish(reply.requestId, result: .success(reply)) }
        } catch {
            if let active { finish(active, result: .failure(GalleryError.invalidReply)) }
        }
    }

    private func request(_ message: GlassMediaRequest) async throws -> GlassMediaReply {
        try Task.checkCancellation()
        guard connected else { throw GalleryError.disconnected }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard pending.count < 128 else {
                    continuation.resume(throwing: GalleryError.remote("Too many thumbnail requests. Try again.")); return
                }
                pending[message.requestId] = Pending(request: message, continuation: continuation)
                if message.operation == "Thumbnail" { queue.append(message.requestId) }
                else { queue.insert(message.requestId, at: 0) }
                sendNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(message.requestId, result: .failure(CancellationError())) }
        }
    }

    private func sendNext() {
        guard active == nil, connected else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let waiting = pending[id] else { continue }
            active = id
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finish(id, result: .failure(GalleryError.timeout))
            }
            guard let server else { finish(id, result: .failure(GalleryError.disconnected)); return }
            server.send(service: "MediaLibrary", type: GlassProtocol.mediaLibraryRequestType,
                        payload: waiting.request) { [weak self] sent in
                if !sent { self?.finish(id, result: .failure(GalleryError.disconnected)) }
            }
            return
        }
    }

    private func finish(_ id: String, result: Result<GlassMediaReply, Error>) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        if active == id { active = nil; timeout?.cancel(); timeout = nil }
        waiting.continuation.resume(with: result)
        sendNext()
    }

    private func failPending(with error: Error) {
        let waiting = pending.values.map { $0.continuation }
        pending.removeAll()
        queue.removeAll()
        active = nil
        timeout?.cancel()
        timeout = nil
        waiting.forEach { $0.resume(throwing: error) }
    }
}
