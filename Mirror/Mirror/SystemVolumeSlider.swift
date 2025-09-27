import SwiftUI
import MediaPlayer

#if os(iOS) || os(tvOS)
/// A SwiftUI wrapper for the system volume slider.
/// Uses MPVolumeView under the hood to control the device's output volume.
public struct SystemVolumeSlider: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // On iOS/tvOS 13+, MPVolumeView.showsRouteButton is deprecated.
        // If you need a route picker, use AVRoutePickerView alongside this slider.
        if #available(iOS 13.0, tvOS 13.0, *) {
            // Do nothing here to avoid deprecated API usage on modern OS versions.
        } else {
            // Hide route button to show only the slider on older OS versions.
            view.showsRouteButton = false
        }
        return view
    }

    public func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // SwiftUI's .tint modifier will set tintColor automatically for UIViewRepresentable
        // No-op here; MPVolumeView picks up tintColor from environment.
    }
}

#elseif os(macOS)
// macOS does not have MPVolumeView. This is a placeholder that renders a disabled slider.
public struct SystemVolumeSlider: View {
    public init() {}
    public var body: some View {
        #if canImport(AppKit)
        HStack {
            Image(systemName: "speaker.fill")
            Slider(value: .constant(0.5))
                .disabled(true)
            Image(systemName: "speaker.wave.3.fill")
        }
        .help("System volume control is not available on macOS via MPVolumeView.")
        #else
        EmptyView()
        #endif
    }
}
#endif


