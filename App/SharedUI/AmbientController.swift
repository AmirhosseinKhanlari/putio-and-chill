import AMDBCore
import Observation
import SwiftUI

@Observable @MainActor
final class AmbientController {
    private(set) var palette = AmbientPalette.neutral
    @ObservationIgnored private var task: Task<Void, Never>?

    func focus(_ item: CatalogItem) {
        focus(path: item.backdropPath ?? item.posterPath, seed: item.title)
    }

    func focus(path: String?, seed: String) {
        task?.cancel()
        task = Task {
            var next = AmbientPalette.seeded(seed)
            if let url = CatalogClient.imageURL(path, size: "w300"), let extracted = await ImagePipeline.shared.palette(for: url) {
                next = extracted
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { palette = next }
        }
    }
}
