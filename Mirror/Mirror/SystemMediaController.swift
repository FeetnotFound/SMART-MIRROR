import Foundation
import MediaPlayer
import AVFAudio
#if canImport(UIKit)
import UIKit
#endif

/// Centralized helper to perform media transport commands and adjust system volume.
/// Uses MPMusicPlayerController for transport and MPVolumeView for volume changes.
@MainActor
enum SystemMediaController {
    // MARK: - Transport controls
    static func togglePlayPause() {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch player.playbackState {
        case .playing:
            player.pause()
        default:
            player.play()
        }
    }

    static func nextTrack() {
        let player = MPMusicPlayerController.systemMusicPlayer
        player.skipToNextItem()
    }

    static func previousTrack() {
        let player = MPMusicPlayerController.systemMusicPlayer
        player.skipToPreviousItem()
    }

    // MARK: - Volume control (10% step by default)
    static func volumeUp(step: Float = 0.10) {
        adjustVolume(by: abs(step))
    }

    static func volumeDown(step: Float = 0.10) {
        adjustVolume(by: -abs(step))
    }

    private static func adjustVolume(by delta: Float) {
        let current = AVAudioSession.sharedInstance().outputVolume
        let newValue = clamp(current + delta, min: 0.0, max: 1.0)
        setSystemVolume(newValue)
    }

    private static func clamp(_ v: Float, min: Float, max: Float) -> Float { Swift.max(min, Swift.min(max, v)) }

    /// Programmatically set the system volume using MPVolumeView's internal slider.
    /// Note: Apple restricts programmatic volume changes; this uses the documented MPVolumeView approach.
    private static func setSystemVolume(_ value: Float) {
        #if canImport(UIKit)
        guard let slider = obtainHiddenVolumeSlider() else {
            print("[SystemMediaController] Could not obtain MPVolumeView slider to set volume.")
            return
        }
        let clamped = clamp(value, min: 0.0, max: 1.0)
        if abs(slider.value - clamped) < 0.001 { return }
        slider.setValue(clamped, animated: false)
        // Send value changed events so the system applies it
        slider.sendActions(for: [.touchUpInside, .valueChanged])
        #endif
    }

    // Keep a single hidden MPVolumeView around
    #if canImport(UIKit)
    private static var hiddenVolumeView: MPVolumeView?

    private static func obtainHiddenVolumeSlider() -> UISlider? {
        if hiddenVolumeView == nil {
            let vv = MPVolumeView(frame: .zero)
            vv.alpha = 0.0001
            vv.isHidden = true
            // Try to attach to a window to ensure it works reliably
            if let window = firstActiveWindow() {
                window.addSubview(vv)
            }
            hiddenVolumeView = vv
        }
        guard let view = hiddenVolumeView else { return nil }
        // Find the UISlider inside MPVolumeView
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            return slider
        }
        // If not found yet, force layout and try again
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view.subviews.compactMap { $0 as? UISlider }.first
    }

    private static func firstActiveWindow() -> UIWindow? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
    #endif
}
