import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Local audio picker

/// UIKit-backed document picker for local audio imports.
///
/// SwiftUI's `.fileImporter` is convenient, but on iOS it can silently fail for
/// some provider-backed audio files: the sheet opens, files look selectable, and
/// then the app receives either no usable URL or a security-scoped URL that is
/// not ready for copying yet. The UIKit picker with `asCopy: true` gives the app
/// an import-style URL and lets the library store still use security-scoped
/// coordinated reads when the provider requires them.
struct LocalAudioDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.allowedAudioTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    static var allowedAudioTypes: [UTType] {
        var result: [UTType] = [
            .audio,
            .mp3,
            .mpeg4Audio,
            .wav,
            .aiff
        ]

        let extensions = [
            "m4a", "aac", "flac", "alac", "ogg", "oga", "opus", "caf", "mp4"
        ]

        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !result.contains(type) {
                result.append(type)
            }
        }

        return result
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(
            onPick: @escaping ([URL]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
