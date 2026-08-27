import AVKit
import SwiftUI

struct AirPlayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .white
        picker.activeTintColor = UIColor(AG.amber)
        picker.accessibilityLabel = "Выбрать устройство воспроизведения"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = .white
        picker.activeTintColor = UIColor(AG.amber)
    }
}
