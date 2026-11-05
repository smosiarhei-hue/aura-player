import Foundation

public enum SeparatorFactory {
    /// Looks for `HTDemucs.mlmodelc` in the host app bundle (drop the compiled model into the Sonivo target).
    /// FP16 packages are rejected by Core ML. Without the model this returns passthrough and does not cut the mix.
    public static func make() async throws -> any StemSeparating {
        let bundled = Bundle.main.url(forResource: "HTDemucs", withExtension: "mlmodelc")
        let installed = HTDemucsModelStore.shared.installedPackageURL()
        guard let url = bundled ?? installed else {
            return PassthroughSeparator()
        }
        return try await Task.detached(priority: .userInitiated) {
            try CoreMLStemSeparator(modelURL: url)
        }.value
    }
}
