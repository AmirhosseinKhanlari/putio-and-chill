import AMDBCore
import SwiftUI

/// Remote artwork with a colored placeholder seeded from the title, so missing art still looks intentional.
/// The view always takes exactly the size it is offered: artwork larger than that is cropped (fill) or
/// scaled down (fit), never allowed to widen the surrounding layout.
struct RemoteImage: View {
    private let url: URL?
    private let seed: String
    private let contentMode: ContentMode
    private let alignment: Alignment
    private let neutral: Bool
    @State private var image: UIImage?

    init(path: String?, size: String, seed: String, contentMode: ContentMode = .fill, alignment: Alignment = .center,
         neutral: Bool = false) {
        self.url = CatalogClient.imageURL(path, size: size)
        self.seed = seed
        self.contentMode = contentMode
        self.alignment = alignment
        self.neutral = neutral
    }

    init(url: URL?, seed: String) {
        self.url = url
        self.seed = seed
        self.contentMode = .fill
        self.alignment = .center
        self.neutral = false
    }

    var body: some View {
        base
            .overlay(alignment: alignment) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                image = nil
                guard let url else { return }
                let loaded = await ImagePipeline.shared.image(for: url)
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }

    @ViewBuilder private var base: some View {
        #if os(tvOS)
        // Design A on the TV: quiet gray while art loads, never colored placeholders.
        if contentMode == .fill { Color(white: 0.1) } else { Color.clear }
        #else
        // Gray while artwork downloads; the colored card only when there is no artwork at all.
        if neutral || (url != nil && contentMode == .fill) {
            Color.white.opacity(0.08)
        } else if contentMode == .fill {
            let palette = AmbientPalette.seeded(seed)
            LinearGradient(colors: [palette.primary.color, palette.secondary.color], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color.clear
        }
        #endif
    }
}
