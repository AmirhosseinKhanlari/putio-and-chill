import AMDBCore
import SwiftUI

/// Remote artwork with a colored placeholder seeded from the title, so missing art still looks intentional.
struct RemoteImage: View {
    private let url: URL?
    private let seed: String
    private let contentMode: ContentMode
    @State private var image: UIImage?

    init(path: String?, size: String, seed: String, contentMode: ContentMode = .fill) {
        self.url = CatalogClient.imageURL(path, size: size)
        self.seed = seed
        self.contentMode = contentMode
    }

    init(url: URL?, seed: String) {
        self.url = url
        self.seed = seed
        self.contentMode = .fill
    }

    var body: some View {
        ZStack {
            if contentMode == .fill {
                let palette = AmbientPalette.seeded(seed)
                LinearGradient(colors: [palette.primary.color, palette.secondary.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ImagePipeline.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}
