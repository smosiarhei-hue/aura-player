import AVKit
import SwiftUI

struct AirPlayButtonView: UIViewRepresentable {
    var tintColor: UIColor = .white.withAlphaComponent(0.70)
    var activeTintColor: UIColor = UIColor(AG.amber)

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.backgroundColor = .clear
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentHuggingPriority(.required, for: .vertical)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .vertical)
        picker.accessibilityLabel = "AirPlay"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
    }
}
