import UIKit

actor ImagePipeline {
    static let shared = ImagePipeline()

    private let cache = NSCache<NSURL, UIImage>()
    private var palettes: [URL: AmbientPalette] = [:]

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let image = UIImage(data: data) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: url as NSURL)
        return prepared
    }

    func palette(for url: URL) async -> AmbientPalette? {
        if let hit = palettes[url] { return hit }
        guard let cgImage = await image(for: url)?.cgImage else { return nil }
        let palette = AmbientPalette.extract(from: cgImage)
        palettes[url] = palette
        return palette
    }
}
