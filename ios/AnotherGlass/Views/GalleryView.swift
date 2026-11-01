import AVKit
import SwiftUI

private enum GallerySelection: Identifiable {
    case remote(GlassMediaItem), local(DownloadedMedia)
    var id: String {
        switch self {
        case .remote(let item): return item.cacheKey
        case .local(let item): return item.id.uuidString
        }
    }
    var item: GlassMediaItem {
        switch self {
        case .remote(let item): return item
        case .local(let item): return item.original
        }
    }
    var local: DownloadedMedia? { if case .local(let item) = self { return item }; return nil }
    var remote: GlassMediaItem? { if case .remote(let item) = self { return item }; return nil }
}

struct GalleryView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var gallery: MediaGallery
    @ObservedObject private var server: GlassServer
    @State private var source = 0
    @State private var selection: GallerySelection?
    @Environment(\.scenePhase) private var scenePhase
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    init(model: CompanionModel) {
        self.model = model
        gallery = model.gallery
        server = model.server
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GlassPageHeading(title: "Gallery", subtitle: "Photos and video, through your own eyes")
                Picker("Media source", selection: $source) {
                    Text("On Glass").tag(0)
                    Text("Downloaded").tag(1)
                }
                .pickerStyle(.segmented)
                HStack {
                    GlassStatus(text: source == 1 ? "Available offline" : gallery.connected ? "Glass connected" : "Wi-Fi connection required", active: source == 0 && gallery.connected)
                    Spacer(minLength: 4)
                    Text(source == 1 ? gallery.downloads.count.formatted() : gallery.items.count.formatted())
                        .font(.caption.monospaced()).foregroundStyle(GlassStyle.muted)
                }

                if let id = gallery.downloadingID {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Downloading original").font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Cancel") { gallery.cancelDownload() }.font(.subheadline)
                        }
                        ProgressView(value: gallery.downloadProgress)
                        Text("\(Int(gallery.downloadProgress * 100))% · \(gallery.items.first { $0.id == id }?.name ?? "Glass media")")
                            .font(.caption).foregroundStyle(GlassStyle.secondary).lineLimit(1)
                    }
                    .padding(20).background(GlassStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                }

                if let error = gallery.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                        if source == 0, gallery.connected {
                            Button("Try again") { Task { await gallery.refresh() } }
                        }
                    }
                    .foregroundStyle(GlassStyle.warning)
                }

                if source == 0 { remoteGrid } else { downloadedGrid }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 32)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(GlassStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(GlassStyle.background, for: .navigationBar)
        .toolbar {
            if source == 0, gallery.connected {
                Button {
                    Task { await gallery.refresh() }
                } label: { Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh Glass library") }
                .disabled(gallery.isLoading)
            }
        }
        .refreshable { if source == 0 { await gallery.refresh() } }
        .task(id: "\(gallery.connected)-\(model.selectedTab)-\(scenePhase)") {
            guard gallery.connected, model.selectedTab == 2, scenePhase == .active else { return }
            await gallery.refresh()
            // Glass sends invalidations when its local media index changes. No constant network polling.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if gallery.needsRefresh, gallery.downloadingID == nil { await gallery.refresh() }
            }
        }
        .sheet(item: $selection) { selected in
            NavigationStack {
                MediaDetailView(gallery: gallery, selection: selected)
            }
        }
    }

    @ViewBuilder
    private var remoteGrid: some View {
        if server.mode == .bluetooth {
            GlassPanel {
                GlassEmptyState(symbol: "wifi", title: "Your captures travel over Wi-Fi", detail: "Bluetooth LE handles the background companion link. Switch to Wi-Fi to browse photos and download originals. Your downloads are always available offline.")
                Button("Open connection options") { model.selectedTab = 0 }
                    .buttonStyle(GlassPrimaryButtonStyle())
            }
        } else if !gallery.connected {
            GlassPanel {
                GlassEmptyState(symbol: "photo.on.rectangle.angled", title: "See what you've captured", detail: "Connect Glass over Wi-Fi to browse its photos and video. Previously saved originals are in Downloaded.")
                Button("Connect Glass") { model.selectedTab = 0 }
                    .buttonStyle(GlassPrimaryButtonStyle())
            }
        } else if gallery.items.isEmpty {
            if gallery.isLoading {
                ProgressView("Reading the Glass library…").frame(maxWidth: .infinity).padding(.vertical, 50)
            } else if gallery.error == nil {
                GlassEmptyState(symbol: "camera", title: "Ready for your first capture", detail: "Photos and video in Glass's shared media library appear here. Pull to refresh after taking a photo or recording a video.")
            }
        } else {
            Text("Browse media stored on Glass. Originals download only when you choose.")
                .font(.subheadline).foregroundStyle(GlassStyle.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(gallery.items) { item in
                    Button {
                        selection = .remote(item)
                    } label: {
                        RemoteMediaTile(gallery: gallery, item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            if gallery.hasMore {
                Button {
                    Task { await gallery.loadMore() }
                } label: {
                    if gallery.isLoading { ProgressView() }
                    else { Text("Load more") }
                }
                .frame(maxWidth: .infinity).padding().disabled(gallery.isLoading)
            }
        }
    }

    @ViewBuilder
    private var downloadedGrid: some View {
        if gallery.downloads.isEmpty {
            GlassPanel {
                GlassEmptyState(symbol: "arrow.down.to.line", title: "Keep the original", detail: "Open a capture in On Glass and choose Download original. It stays here when Glass is disconnected, ready to save or share.")
            }
        } else {
            Text("Originals saved on this iPhone. Open an item to save to Photos or share to Files.")
                .font(.subheadline).foregroundStyle(GlassStyle.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(gallery.downloads) { item in
                    Button {
                        selection = .local(item)
                    } label: { DownloadedMediaTile(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct RemoteMediaTile: View {
    @ObservedObject var gallery: MediaGallery
    let item: GlassMediaItem
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaTileImage(image: image, isVideo: item.isVideo, failed: failed)
                .overlay(alignment: .bottomLeading) {
                    if gallery.sessionDownloads[item.cacheKey] != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(GlassStyle.positive)
                            .padding(8).accessibilityLabel("Downloaded")
                    }
                }
            Text(item.name).font(.caption).lineLimit(1)
            Text(item.sizeDescription).font(.caption.monospaced()).foregroundStyle(GlassStyle.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.isVideo ? "Video" : "Photo"), \(item.name), \(item.sizeDescription)")
        .task(id: item.cacheKey) {
            do {
                let result = try await gallery.thumbnail(for: item)
                guard !Task.isCancelled else { return }
                image = result
                failed = result == nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct DownloadedMediaTile: View {
    let item: DownloadedMedia
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaTileImage(image: image, isVideo: item.original.isVideo, failed: loaded && image == nil)
            Text(item.original.name).font(.caption).lineLimit(1)
            Text(item.original.sizeDescription).font(.caption.monospaced()).foregroundStyle(GlassStyle.secondary)
        }
        .task(id: item.id) {
            image = await MediaImages.preview(url: item.thumbnailURL, isVideo: false, pixels: 400)
            if image == nil {
                image = await MediaImages.preview(url: item.fileURL, isVideo: item.original.isVideo, pixels: 400)
            }
            loaded = true
        }
    }
}

private struct MediaTileImage: View {
    let image: UIImage?
    let isVideo: Bool
    let failed: Bool
    var body: some View {
        GlassStyle.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { proxy in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    }
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(GlassStyle.secondary)
                } else { ProgressView() }
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideo {
                    Image(systemName: "play.fill").font(.caption).padding(8)
                        .background(.black.opacity(0.55), in: Circle()).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct MediaDetailView: View {
    @ObservedObject var gallery: MediaGallery
    let selection: GallerySelection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var savedToPhotos = false
    @State private var actionError: String?
    @State private var photosDenied = false
    @State private var previewAttempt = 0
    @State private var previewLoading = true

    private var item: GlassMediaItem { selection.item }
    private var remote: GlassMediaItem? { selection.remote }
    private var local: DownloadedMedia? { selection.local }
    private var downloaded: DownloadedMedia? {
        local ?? remote.flatMap { gallery.sessionDownloads[$0.cacheKey] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let player { VideoPlayer(player: player).frame(height: 260) }
                    else if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
                    else if previewLoading {
                        ProgressView("Loading preview…").frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Preview unavailable", systemImage: item.isVideo ? "video" : "photo",
                                               description: Text("You can still download the original from Glass."))
                    }
                }
                .frame(minHeight: 180)
                .background(.black, in: RoundedRectangle(cornerRadius: 12))
                if image == nil, player == nil, !previewLoading {
                    Button("Retry preview") { previewAttempt += 1 }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.headline.weight(.medium)).textSelection(.enabled)
                    Text("\(item.isVideo ? "Video" : "Photo") · \(item.sizeDescription)").foregroundStyle(GlassStyle.secondary)
                    Text(item.date, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption).foregroundStyle(GlassStyle.secondary)
                }

                if let downloaded {
                    Label("Original saved on iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(GlassStyle.positive)
                    Button {
                        saving = true
                        actionError = nil
                        photosDenied = false
                        Task {
                            do { try await MediaFiles.saveToPhotos(downloaded); savedToPhotos = true }
                            catch {
                                actionError = error.localizedDescription
                                if case GalleryError.photosPermission = error { photosDenied = true }
                            }
                            saving = false
                        }
                    } label: {
                        Label(saving ? "Saving…" : savedToPhotos ? "Saved to Photos" : "Save to Photos", systemImage: "photo.badge.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle()).disabled(saving || savedToPhotos)
                    ShareLink(item: downloaded.fileURL) {
                        Label("Share / Save to Files", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if gallery.downloadingID == item.id {
                    ProgressView("Downloading original · \(Int(gallery.downloadProgress * 100))%", value: gallery.downloadProgress)
                    Button("Cancel download", role: .cancel) { gallery.cancelDownload() }
                } else if let remote {
                    Button { gallery.download(remote) } label: {
                        Label(item.isVideo ? "Download original to play" : "Download original", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                    .disabled(!gallery.connected || gallery.downloadingID != nil)
                    Text("This preview is a thumbnail from Glass. Downloading keeps the original quality and embedded metadata.")
                        .font(.footnote).foregroundStyle(GlassStyle.secondary)
                }

                if let message = actionError ?? gallery.error { Text(message).font(.subheadline).foregroundStyle(GlassStyle.warning) }
                if photosDenied {
                    Button("Open Photos permissions") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            .padding(24)
        }
        .background(GlassStyle.background)
        .toolbarBackground(GlassStyle.background, for: .navigationBar)
        .navigationTitle(item.isVideo ? "Video" : "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task(id: "\(downloaded?.id.uuidString ?? item.cacheKey)-\(previewAttempt)") {
            previewLoading = true
            defer { if !Task.isCancelled { previewLoading = false } }
            player?.pause()
            player = nil
            if let downloaded {
                if item.isVideo { player = AVPlayer(url: downloaded.fileURL) }
                else {
                    let result = await MediaImages.preview(url: downloaded.fileURL, isVideo: false, pixels: 2400)
                    if !Task.isCancelled { image = result }
                }
            } else if let remote {
                let result = try? await gallery.thumbnail(for: remote)
                if !Task.isCancelled { image = result }
            }
        }
        .onChange(of: gallery.connected) { _, connected in
            if !connected, local == nil, downloaded == nil { dismiss() }
        }
        .onDisappear { player?.pause() }
    }
}
