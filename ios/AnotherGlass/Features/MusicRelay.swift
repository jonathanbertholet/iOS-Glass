import Combine
import Foundation
import MediaPlayer

/// Controls only Apple's Music app. This is not Android's global media-session API.
@MainActor
final class MusicRelay: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Music sharing is off"
    @Published private(set) var current = GlassMediaState()

    var onState: ((GlassMediaState) -> Void)?
    private var player: MPMusicPlayerController?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Task<Void, Never>?
    private var permissionRequest: UUID?

    func setEnabled(_ value: Bool) {
        permissionRequest = nil
        if !value { stop(); return }
        let request = UUID()
        permissionRequest = request
        status = "Waiting for Music access…"
        MPMediaLibrary.requestAuthorization { [weak self] authorization in
            Task { @MainActor in
                guard let self, self.permissionRequest == request else { return }
                self.permissionRequest = nil
                guard authorization == .authorized else {
                    self.status = "Allow Media & Apple Music access in Settings"
                    return
                }
                self.start()
            }
        }
    }

    func refresh() {
        guard enabled, let player else { return }
        let item = player.nowPlayingItem
        var state = GlassMediaState()
        switch player.playbackState {
        case .playing: state.playbackState = "Playing"
        case .paused: state.playbackState = "Paused"
        case .interrupted: state.playbackState = "Paused"
        case .seekingForward, .seekingBackward: state.playbackState = "Buffering"
        default: state.playbackState = item == nil ? "None" : "Stopped"
        }
        state.title = item?.title
        state.artist = item?.artist
        state.album = item?.albumTitle
        state.positionMs = Self.milliseconds(player.currentPlaybackTime)
        state.durationMs = Self.milliseconds(item?.playbackDuration ?? 0)
        // Android PlaybackState action bits, as consumed by the Glass media cards.
        state.actionsMask = item == nil ? 0 : 4 | 2 | 16 | 32 | 256 | 512
        current = state
        status = item?.title ?? "Start a track in the Music app"
        onState?(state)
    }

    func handle(_ command: GlassMediaCommand) {
        guard enabled, let player, player.nowPlayingItem != nil else { return }
        switch command.command {
        case "Play": player.play()
        case "Pause": player.pause()
        case "TogglePlayPause":
            if player.playbackState == .playing { player.pause() } else { player.play() }
        case "Next": player.skipToNextItem()
        case "Previous": player.skipToPreviousItem()
        case "SeekTo":
            let duration = player.nowPlayingItem?.playbackDuration ?? 0
            player.currentPlaybackTime = min(max(0, Double(command.seekToMs ?? 0) / 1000), duration)
        default: return
        }
        refresh()
        // Music state notifications also provide the eventual result of a skip.
    }

    private func start() {
        guard !enabled else { refresh(); return }
        enabled = true
        let player = MPMusicPlayerController.systemMusicPlayer
        self.player = player
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        player.beginGeneratingPlaybackNotifications()
        refresh()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.refresh()
            }
        }
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        player?.endGeneratingPlaybackNotifications()
        player = nil
        enabled = false
        status = "Music sharing is off"
        current = GlassMediaState()
        onState?(current) // Remove a previously published Glass media card.
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(seconds * 1000, Double(Int32.max)))
    }
}
