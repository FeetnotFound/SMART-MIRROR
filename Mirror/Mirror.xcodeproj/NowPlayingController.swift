import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI

final class NowPlayingController: ObservableObject {
    static let shared = NowPlayingController()

    private let player = AVPlayer()
    private var timeObserver: Any?

    @Published var isPlaying: Bool = false
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var duration: Double?
    @Published var elapsed: Double = 0

    private init() {
        setupRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    func play(url: URL, title: String, artist: String, artwork: UIImage? = nil, duration: Double? = nil) {
        let playerItem = AVPlayerItem(url: url)
        self.player.replaceCurrentItem(with: playerItem)
        self.title = title
        self.artist = artist
        self.duration = duration ?? playerItem.asset.duration.seconds
        self.elapsed = 0

        startProgressUpdates()
        updateNowPlayingInfo(artwork: artwork)
        play()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        player.play()
        isPlaying = true
        updatePlaybackRate()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updatePlaybackRate()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: time) { [weak self] _ in
            self?.elapsed = seconds
            self?.updateNowPlayingInfo(artwork: nil)
        }
    }

    // MARK: - Private Helpers

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo(artwork: UIImage?) {
        var nowPlayingInfo: [String: Any] = [:]

        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist

        if let duration = duration {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let artwork = artwork {
            let mediaArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = mediaArtwork
        } else if let existingArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = existingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updatePlaybackRate() {
        updateNowPlayingInfo(artwork: nil)
    }

    private func updateElapsedTime() {
        guard let currentItem = player.currentItem else { return }
        elapsed = currentItem.currentTime().seconds
        updateNowPlayingInfo(artwork: nil)
    }

    private func startProgressUpdates() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        elapsed = player.currentTime().seconds

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: DispatchQueue.main) { [weak self] _ in
            self?.updateElapsedTime()
        }
    }

    @objc private func playerDidFinishPlaying() {
        pause()
        elapsed = duration ?? 0
        updateNowPlayingInfo(artwork: nil)
    }
}
