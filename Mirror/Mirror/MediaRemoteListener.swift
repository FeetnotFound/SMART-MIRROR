// MediaRemoteListener.swift
// Centralized "ears" for media remote commands and volume changes.

import Foundation
import AVFAudio
import Combine
#if canImport(MediaPlayer)
import MediaPlayer
#endif

#if os(iOS) || os(tvOS)
/// Listens for system media remote commands (play, pause, skip) and volume changes.
/// - Usage:
///   - Call `try? MediaRemoteListener.shared.activate()` once (e.g., on app launch or view appear).
///   - Set the optional closure handlers (e.g., `onPlay`, `onSkipBackward`).
///   - Optionally observe `volume` and `lastCommand` via `@Published`.
public final class MediaRemoteListener: NSObject, ObservableObject {
    public static let shared = MediaRemoteListener()

    // MARK: - Published state
    @Published public private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @Published public private(set) var lastCommand: Command = .none

    // MARK: - Command type
    public enum Command: Equatable {
        case none
        case play
        case pause
        case togglePlayPause
        case nextTrack
        case previousTrack
        case skipForward(seconds: TimeInterval)
        case skipBackward(seconds: TimeInterval)
        case changePlaybackPosition(seconds: TimeInterval)
    }

    // MARK: - Callbacks
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onTogglePlayPause: (() -> Void)?
    public var onNextTrack: (() -> Void)?
    public var onPreviousTrack: (() -> Void)?
    public var onSkipForward: ((TimeInterval) -> Void)?
    public var onSkipBackward: ((TimeInterval) -> Void)?
    public var onChangePlaybackPosition: ((TimeInterval) -> Void)?

    // MARK: - Private
    private var volumeObservation: NSKeyValueObservation?
    private var isActive = false

    private override init() {
        super.init()
    }

    deinit {
        deactivate()
    }

    // MARK: - Activation / Deactivation
    /// Activates the audio session and registers for remote commands + volume observation.
    @discardableResult
    public func activate(preferredSkipInterval: TimeInterval = 15) throws -> Bool {
        guard !isActive else { return false }

        // Configure the audio session for playback so we can receive remote commands.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])

        // Start observing system output volume.
        volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
            self?.volume = session.outputVolume
        }

        // Register for remote commands.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipInterval)]

        center.playCommand.addTarget(self, action: #selector(handlePlay))
        center.pauseCommand.addTarget(self, action: #selector(handlePause))
        center.togglePlayPauseCommand.addTarget(self, action: #selector(handleTogglePlayPause))
        center.nextTrackCommand.addTarget(self, action: #selector(handleNextTrack))
        center.previousTrackCommand.addTarget(self, action: #selector(handlePreviousTrack))
        center.skipForwardCommand.addTarget(self, action: #selector(handleSkipForward(event:)))
        center.skipBackwardCommand.addTarget(self, action: #selector(handleSkipBackward(event:)))
        center.changePlaybackPositionCommand.addTarget(self, action: #selector(handleChangePlaybackPosition(event:)))

        isActive = true
        return true
    }

    /// Unregisters remote command handlers and stops observing volume.
    public func deactivate() {
        guard isActive else { return }
        isActive = false

        // Stop observing volume.
        volumeObservation?.invalidate()
        volumeObservation = nil

        // Remove all remote command targets.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(self)
        center.pauseCommand.removeTarget(self)
        center.togglePlayPauseCommand.removeTarget(self)
        center.nextTrackCommand.removeTarget(self)
        center.previousTrackCommand.removeTarget(self)
        center.skipForwardCommand.removeTarget(self)
        center.skipBackwardCommand.removeTarget(self)
        center.changePlaybackPositionCommand.removeTarget(self)

        // Optionally deactivate session if you own it exclusively.
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }

    // MARK: - Minimal Now Playing support (optional)
    /// Setting now playing info helps the system surface your controls.
    /// Call this when your playback state changes.
    public func setNowPlaying(title: String,
                              artist: String? = nil,
                              duration: TimeInterval? = nil,
                              position: TimeInterval? = nil,
                              isPlaying: Bool? = nil) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let position { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        if let isPlaying { info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Handlers
    @objc private func handlePlay() -> MPRemoteCommandHandlerStatus {
        lastCommand = .play
        onPlay?()
        return .success
    }

    @objc private func handlePause() -> MPRemoteCommandHandlerStatus {
        lastCommand = .pause
        onPause?()
        return .success
    }

    @objc private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
        lastCommand = .togglePlayPause
        onTogglePlayPause?()
        return .success
    }

    @objc private func handleNextTrack() -> MPRemoteCommandHandlerStatus {
        lastCommand = .nextTrack
        onNextTrack?()
        return .success
    }

    @objc private func handlePreviousTrack() -> MPRemoteCommandHandlerStatus {
        lastCommand = .previousTrack
        onPreviousTrack?()
        return .success
    }

    @objc private func handleSkipForward(event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        let interval = event.interval
        lastCommand = .skipForward(seconds: interval)
        onSkipForward?(interval)
        return .success
    }

    @objc private func handleSkipBackward(event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus {
        let interval = event.interval
        lastCommand = .skipBackward(seconds: interval)
        onSkipBackward?(interval)
        return .success
    }

    @objc private func handleChangePlaybackPosition(event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus {
        let positionTime = event.positionTime
        lastCommand = .changePlaybackPosition(seconds: positionTime)
        onChangePlaybackPosition?(positionTime)
        return .success
    }
}

#else
// On platforms without MPRemoteCommandCenter (e.g., macOS app without media controls), provide a no-op stub.
public final class MediaRemoteListener: ObservableObject {
    public static let shared = MediaRemoteListener()
    @Published public private(set) var volume: Float = 0
    @Published public private(set) var lastCommand: Command = .none
    public enum Command: Equatable { case none }

    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onTogglePlayPause: (() -> Void)?
    public var onNextTrack: (() -> Void)?
    public var onPreviousTrack: (() -> Void)?
    public var onSkipForward: ((TimeInterval) -> Void)?
    public var onSkipBackward: ((TimeInterval) -> Void)?
    public var onChangePlaybackPosition: ((TimeInterval) -> Void)?

    private init() {}
    @discardableResult public func activate(preferredSkipInterval: TimeInterval = 15) throws -> Bool { false }
    public func deactivate() {}
    public func setNowPlaying(title: String, artist: String? = nil, duration: TimeInterval? = nil, position: TimeInterval? = nil, isPlaying: Bool? = nil) {}
}
#endif

