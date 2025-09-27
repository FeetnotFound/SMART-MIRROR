import SwiftUI
import MediaPlayer

struct SystemVolumeSlider: UIViewRepresentable {
    var showsRouteButton: Bool = false
    var tintColor: UIColor? = nil

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = showsRouteButton
        if let tintColor {
            view.tintColor = tintColor
        }
        // Remove background for seamless SwiftUI appearance
        view.setVolumeThumbImage(nil, for: .normal)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.showsRouteButton = showsRouteButton
        if let tintColor {
            uiView.tintColor = tintColor
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        Text("Device Volume")
        SystemVolumeSlider(showsRouteButton: false)
            .frame(height: 44)
            .padding()
    }
    .padding()
}
