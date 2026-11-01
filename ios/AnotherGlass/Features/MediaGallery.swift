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
    private static let chunkBytes = 96 * 1024
    private static let readWindow = 4
    private var active: Set<String> = []
    private var timeouts: [String: Task<Void, Never>] = [:]

    private struct DownloadChunk: Sendable {
        let offset: Int64
        let data: Data
    }

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
        guard item.size > 0, item.size <= 2 * 1024 * 1024 * 1024 else { error = GalleryError.fileTooLarge.localizedDescription; return }
        downloadingID = item.id
        downloadProgress = 0
        error = nil
        let currentSession = session
        transfer = Task {
            var writer: MediaFileWriter?
            defer {
                transfer = nil
                downloadingID = nil
                sendNext() // Resume thumbnails deferred during the original transfer.
            }
            do {
                let thumbnail = try? await thumbnailBytes(for: item)
                try Task.checkCancellation()
                let file = try MediaFileWriter()
                writer = file
                // Bound both requests and completed out-of-order chunks to one four-chunk
                // window. A slow first reply cannot cause an unbounded reorder buffer.
                try await withThrowingTaskGroup(of: DownloadChunk.self) { group in
                    var requestedOffset: Int64 = 0
                    var writtenOffset: Int64 = 0
                    var ready: [Int64: Data] = [:]
                    var lastProgress = ContinuousClock.now
                    while writtenOffset < item.size {
                        try Task.checkCancellation()
                        let windowEnd = min(item.size, writtenOffset + Int64(Self.chunkBytes * Self.readWindow))
                        while requestedOffset < windowEnd {
                            let offset = requestedOffset
                            let count = Int(min(Int64(Self.chunkBytes), item.size - offset))
                            group.addTask {
                                try await self.readChunk(item, offset: offset, count: count, session: currentSession)
                            }
                            requestedOffset += Int64(count)
                        }
                        guard let chunk = try await group.next() else { throw GalleryError.invalidReply }
                        ready[chunk.offset] = chunk.data
                        while let bytes = ready.removeValue(forKey: writtenOffset) {
                            try Task.checkCancellation()
                            guard currentSession == session else { throw GalleryError.disconnected }
                            try await file.append(bytes)
                            writtenOffset += Int64(bytes.count)
                        }
                        let now = ContinuousClock.now
                        if writtenOffset == item.size || lastProgress.duration(to: now) >= .milliseconds(100) {
                            downloadProgress = Double(writtenOffset) / Double(item.size)
                            lastProgress = now
                        }
                    }
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
                if !Task.isCancelled, currentSession == session { self.error = error.localizedDescription }
            }
        }
    }

    private func readChunk(_ item: GlassMediaItem, offset: Int64, count: Int, session expectedSession: UUID) async throws -> DownloadChunk {
        try Task.checkCancellation()
        guard expectedSession == session else { throw GalleryError.disconnected }
        let message = GlassMediaRequest(operation: "Read", mediaId: item.id,
                                       revision: item.revision, offset: offset, length: count)
        let reply = try await request(message)
        try Task.checkCancellation()
        guard expectedSession == session, reply.offset == offset, reply.totalBytes == item.size,
              let bytes = reply.data, bytes.count == count else { throw GalleryError.invalidReply }
        return DownloadChunk(offset: offset, data: bytes)
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
            failPending(with: GalleryError.invalidReply)
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
                queue.append(message.requestId)
                sendNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(message.requestId, result: .failure(CancellationError())) }
        }
    }

    private func sendNext() {
        guard connected else { return }
        guard let server else { failPending(with: GalleryError.disconnected); return }
        while true {
            let readCount = active.reduce(0) { $0 + (pending[$1]?.request.operation == "Read" ? 1 : 0) }
            // Reads use a dedicated bounded window; at most one metadata request shares the
            // Glass worker. Other thumbnails wait while downloading to avoid expensive work
            // in front of every file chunk. FIFO within each lane preserves offset order.
            let nextRead = readCount < Self.readWindow ? queue.firstIndex { pending[$0]?.request.operation == "Read" } : nil
            let nextMetadata = active.count == readCount ? queue.firstIndex { id in
                guard let request = pending[id]?.request, request.operation != "Read" else { return false }
                return downloadingID == nil || request.operation != "Thumbnail" || request.mediaId == downloadingID
            } : nil
            guard let index = nextRead ?? nextMetadata else { return }
            let id = queue.remove(at: index)
            guard let waiting = pending[id] else { continue }
            active.insert(id)
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finish(id, result: .failure(GalleryError.timeout))
            }
            server.send(service: "MediaLibrary", type: GlassProtocol.mediaLibraryRequestType,
                        payload: waiting.request) { [weak self] sent in
                if !sent { self?.finish(id, result: .failure(GalleryError.disconnected)) }
            }
        }
    }

    private func finish(_ id: String, result: Result<GlassMediaReply, Error>) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        queue.removeAll { $0 == id }
        active.remove(id)
        timeouts.removeValue(forKey: id)?.cancel()
        waiting.continuation.resume(with: result)
        sendNext()
    }

    private func failPending(with error: Error) {
        let waiting = pending.values.map { $0.continuation }
        pending.removeAll()
        queue.removeAll()
        active.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        waiting.forEach { $0.resume(throwing: error) }
    }
}
