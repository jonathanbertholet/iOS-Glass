import AVFoundation
import Foundation
import ImageIO
import Photos
import UIKit

struct DownloadedMedia: Codable, Identifiable {
    let id: UUID
    let original: GlassMediaItem
    let downloadedAt: Date
    var fileURL: URL { MediaFiles.originals.appendingPathComponent(id.uuidString + "." + original.fileExtension) }
    var thumbnailURL: URL { MediaFiles.metadata.appendingPathComponent(id.uuidString + ".jpg") }
    var metadataURL: URL { MediaFiles.metadata.appendingPathComponent(id.uuidString + ".json") }
}

enum MediaFiles {
    static var originals: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glass Media", isDirectory: true)
    }
    static var metadata: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media Gallery", isDirectory: true)
    }

    static func load() throws -> [DownloadedMedia] {
        guard FileManager.default.fileExists(atPath: metadata.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> DownloadedMedia? in
                guard let bytes = try? Data(contentsOf: url),
                      let item = try? JSONDecoder().decode(DownloadedMedia.self, from: bytes),
                      item.metadataURL.lastPathComponent == url.lastPathComponent,
                      FileManager.default.fileExists(atPath: item.fileURL.path) else { return nil }
                return item
            }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    static func saveToPhotos(_ item: DownloadedMedia) async throws {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else { throw GalleryError.photosPermission }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = item.original.name
            // Retain the downloaded original and all its embedded metadata.
            options.shouldMoveFile = false
            PHAssetCreationRequest.forAsset().addResource(with: item.original.isVideo ? .video : .photo,
                                                        fileURL: item.fileURL, options: options)
        }
    }
}

/// Chunk writes stay off the UI executor; an interrupted download never appears as complete.
actor MediaFileWriter {
    private let temporaryURL: URL
    private var handle: FileHandle?

    init() throws {
        temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: temporaryURL)
    }

    func append(_ bytes: Data) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: bytes)
    }

    func finish(_ item: DownloadedMedia, thumbnail: Data?) throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        try FileManager.default.createDirectory(at: MediaFiles.originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MediaFiles.metadata, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporaryURL, to: item.fileURL)
        do {
            if let thumbnail { try thumbnail.write(to: item.thumbnailURL, options: .atomic) }
            try JSONEncoder().encode(item).write(to: item.metadataURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: item.fileURL)
            try? FileManager.default.removeItem(at: item.thumbnailURL)
            throw error
        }
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}

enum MediaImages {
    static func thumbnail(data: Data, pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return downsample(source, pixels: pixels)
        }.value
    }

    static func preview(url: URL, isVideo: Bool, pixels: Int) async -> UIImage? {
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
            return UIImage(cgImage: image)
        }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return downsample(source, pixels: pixels)
        }.value
    }

    private static func downsample(_ source: CGImageSource, pixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
