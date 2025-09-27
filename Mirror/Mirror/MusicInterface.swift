import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit
import Combine

struct MusicInterface: View {
    @State private var systemNowPlaying = SystemNowPlaying()
    @State private var tickTimer: Timer? = nil
    @State private var isArtworkExpanded: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    artworkView
                    VStack(alignment: .leading, spacing: 4) {
                        Text(systemNowPlaying.title ?? "Nothing Playing")
                            .font(.title3).bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let artist = systemNowPlaying.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    Spacer()
                    stateBadge
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                
                if let elapsed = systemNowPlaying.elapsed, let duration = systemNowPlaying.duration, duration > 0 {
                    VStack(spacing: 6) {
                        ProgressView(value: min(max(elapsed / duration, 0), 1))
                            .tint(.accentColor)
                        HStack {
                            Text(timeString(elapsed))
                            Spacer()
                            Text(timeString(duration))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 28) {
                    Button {
                        sendRemote(.previous)
                    } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }

                    Button {
                        togglePlayPause()
                    } label: {
                        Image(systemName: systemNowPlaying.isPlaying ? "pause.fill" : "play.fill").font(.title)
                    }

                    Button {
                        sendRemote(.next)
                    } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                }
                .buttonStyle(.borderedProminent)
                
                SystemVolumeSlider()
                    .tint(.accentColor)
                    .frame(height: 34)
            }

            Spacer()
        }
        .opacity(isArtworkExpanded ? 0 : 1)
        .overlay(alignment: .center) {
            if isArtworkExpanded {
                expandedArtworkOverlay
            }
        }
        .padding()
        .onAppear {
            configureAudioSession()
            refreshNowPlaying()
            startTicking()
            observeInterruptions()
            observeMusicPlayer()
        }
        .onDisappear {
            removeMusicPlayerObservers()
            stopTicking()
        }
    }

    // MARK: - Subviews
    private var artworkView: some View {
        Group {
            if let image = systemNowPlaying.artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.secondary.opacity(0.15))
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isArtworkExpanded = true
            }
        }
    }

    private var expandedArtworkOverlay: some View {
        Group {
            if let image = systemNowPlaying.artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.secondary.opacity(0.15))
                    Image(systemName: "music.note")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isArtworkExpanded = false
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private var stateBadge: some View {
        Text(systemNowPlaying.isPlaying ? "Playing" : "Paused")
            .font(.caption).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(systemNowPlaying.isPlaying ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundStyle(systemNowPlaying.isPlaying ? .green : .orange)
            .clipShape(Capsule())
    }

    // MARK: - Logic
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Non-fatal: we only read system now playing info
        }
    }

    private func refreshNowPlaying() {
        // Prefer direct player state if available
        let player = MPMusicPlayerController.systemMusicPlayer
        if player.nowPlayingItem != nil {
            updateFromMusicPlayer()
            return
        }
        // Fallback to system Now Playing center
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        systemNowPlaying.update(from: info)
    }

    private func updateFromMusicPlayer() {
        let player = MPMusicPlayerController.systemMusicPlayer
        var info = [String: Any]()
        if let item = player.nowPlayingItem {
            if let title = item.title { info[MPMediaItemPropertyTitle] = title }
            if let artist = item.artist { info[MPMediaItemPropertyArtist] = artist }
            if let album = item.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
            info[MPMediaItemPropertyPlaybackDuration] = item.playbackDuration
            if let artwork = item.artwork { info[MPMediaItemPropertyArtwork] = artwork }
        }
        // Map playback state to rate/isPlaying
        let isPlaying: Bool
        switch player.playbackState {
        case .playing: isPlaying = true
        default: isPlaying = false
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // Elapsed time best-effort
        if let currentTime = player.currentPlaybackTime as Double? {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        systemNowPlaying.update(from: info)
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        // A lightweight timer to nudge elapsed time, poll for changes, and push updates
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Increment elapsed when playing; otherwise just refresh from center
            if systemNowPlaying.isPlaying {
                let dur = systemNowPlaying.duration ?? 0
                if dur > 0 {
                    systemNowPlaying.elapsed = min((systemNowPlaying.elapsed ?? 0) + 1, dur)
                }
            }
            // Pull fresh info (some apps update the center every second)
            refreshNowPlaying()

            // While music is playing, send a now-playing packet each second
            if systemNowPlaying.isPlaying, let payload = buildNowPlayingPayload() {
                Task { @MainActor in
                    MirrorManager.shared.updateNowPlaying(payload)
                    await MirrorManager.shared.sendNowPlaying(payload)
                }
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { _ in
            refreshNowPlaying()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            refreshNowPlaying()
        }
    }

    private func observeMusicPlayer() {
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main) { _ in
            updateFromMusicPlayer()
        }
        NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main) { _ in
            updateFromMusicPlayer()
        }
        // Initial sync from the player
        updateFromMusicPlayer()
    }

    private func removeMusicPlayerObservers() {
        let player = MPMusicPlayerController.systemMusicPlayer
        NotificationCenter.default.removeObserver(self, name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
        NotificationCenter.default.removeObserver(self, name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        player.endGeneratingPlaybackNotifications()
    }

    private func togglePlayPause() {
        let player = MPMusicPlayerController.systemMusicPlayer
        let willPlay: Bool
        switch player.playbackState {
        case .playing:
            player.pause()
            willPlay = false
        default:
            player.play()
            willPlay = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            refreshNowPlaying()
            if willPlay, let payload = buildNowPlayingPayload() {
                Task { @MainActor in
                    MirrorManager.shared.updateNowPlaying(payload)
                    await MirrorManager.shared.sendNowPlaying(payload)
                }
            }
        }
    }

    private enum RemoteCommand {
        case previous
        case next
        case play
        case pause
    }

    private func sendRemote(_ command: RemoteCommand) {
        let player = MPMusicPlayerController.systemMusicPlayer
        var didRequestPlay = false
        switch command {
        case .previous:
            player.skipToPreviousItem()
        case .next:
            player.skipToNextItem()
        case .play:
            player.play()
            didRequestPlay = true
        case .pause:
            player.pause()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            refreshNowPlaying()
            if didRequestPlay, let payload = buildNowPlayingPayload() {
                Task { @MainActor in
                    MirrorManager.shared.updateNowPlaying(payload)
                    await MirrorManager.shared.sendNowPlaying(payload)
                }
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func buildNowPlayingPayload() -> NowPlayingInfo? {
        guard let title = systemNowPlaying.title, !title.isEmpty else { return nil }
        let artist = systemNowPlaying.artist ?? ""
        let album = systemNowPlaying.album ?? ""
        let duration = systemNowPlaying.duration ?? 0
        let position = systemNowPlaying.elapsed ?? 0
        let isPlaying = systemNowPlaying.isPlaying
        return NowPlayingInfo(title: title, artist: artist, album: album, duration: duration, position: position, isPlaying: isPlaying)
    }
}

// MARK: - System Now Playing model
private struct SystemNowPlaying {
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var isPlaying: Bool = false
    var artworkImage: UIImage?

    mutating func update(from info: [String: Any]) {
        if let t = info[MPMediaItemPropertyTitle] as? String { title = t } else { title = nil }
        if let a = info[MPMediaItemPropertyArtist] as? String { artist = a } else { artist = nil }
        if let al = info[MPMediaItemPropertyAlbumTitle] as? String { album = al } else { album = nil }
        if let d = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval { duration = d } else { duration = nil }
        if let e = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval { elapsed = e }
        if let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double { isPlaying = rate > 0.01 } else { isPlaying = false }

        if let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            let size = CGSize(width: 200, height: 200)
            artworkImage = art.image(at: size)
        } else {
            artworkImage = nil
        }
    }
}

#if canImport(SwiftUI)
#Preview {
    MusicInterface()
}
#endif
