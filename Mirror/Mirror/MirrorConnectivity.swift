import Foundation

public func sendNowPlaying(_ info: NowPlayingInfo) async {
    // Forward to the central MirrorManager which owns the connectivity manager
    await MirrorManager.shared.sendNowPlaying(info)
}
