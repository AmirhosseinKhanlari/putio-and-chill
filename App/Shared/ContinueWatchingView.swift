import SwiftUI
import WidgetKit

/// Continue Watching widget content. Lives in App/Shared so the app can render it for previews.
/// Draws its own full-bleed artwork, so the widget runs with content margins disabled.
struct ContinueWatchingView: View {
    let items: [WidgetItem]
    let family: WidgetFamily

    static let background = Color(red: 0.06, green: 0.05, blue: 0.09)

    var body: some View {
        if let first = items.first {
            switch family {
            case .systemSmall: small(first)
            case .systemLarge: large(first, rest: Array(items.dropFirst().prefix(3)))
            default: medium(first, rest: Array(items.dropFirst().prefix(2)))
            }
        } else {
            empty
        }
    }

    // MARK: Families

    private func small(_ item: WidgetItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            WidgetArtwork(item: item)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.9), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                details(item, titleFont: .system(size: 16, weight: .bold), lines: 2)
            }
            .padding(14)
        }
        .overlay(alignment: .topTrailing) { playBadge.padding(12) }
        .foregroundStyle(.white)
        .widgetURL(item.link)
    }

    private func medium(_ item: WidgetItem, rest: [WidgetItem]) -> some View {
        ZStack {
            WidgetArtwork(item: item)
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.35), location: 0.6),
                                   .init(color: .black.opacity(rest.isEmpty ? 0 : 0.55), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            HStack(alignment: .bottom, spacing: 12) {
                hero(item, titleSize: 20)
                if !rest.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(rest) { thumbnail($0) }
                    }
                    .frame(width: 108)
                }
            }
            .padding(14)
        }
        .foregroundStyle(.white)
    }

    private func large(_ item: WidgetItem, rest: [WidgetItem]) -> some View {
        VStack(spacing: 0) {
            ZStack {
                WidgetArtwork(item: item)
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .clear, location: 0.35),
                                       .init(color: Self.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                hero(item, titleSize: 22).padding([.horizontal, .top], 16).padding(.bottom, 6)
            }
            .frame(maxHeight: .infinity)
            if !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rest) { row($0) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(Self.background)
        .foregroundStyle(.white)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle").font(.title2)
            Text("Nothing in progress").font(.footnote.weight(.semibold))
            Text("Start something in AMDB").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.background)
        .widgetURL(URL(string: "amdb://library"))
    }

    // MARK: Pieces

    /// Title block plus a Resume pill; the pill is the tap target for this item.
    private func hero(_ item: WidgetItem, titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTINUE WATCHING").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            if let caption = item.caption {
                Text(caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            Text(item.title).font(.system(size: titleSize, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
            Link(destination: item.link) {
                Label(item.subtitle, systemImage: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white, in: Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func details(_ item: WidgetItem, titleFont: Font, lines: Int) -> some View {
        Group {
            if let caption = item.caption {
                Text(caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            Text(item.title).font(titleFont).lineLimit(lines).minimumScaleFactor(0.8)
            Text(item.subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
        }
    }

    private func thumbnail(_ item: WidgetItem) -> some View {
        Link(destination: item.link) {
            ZStack(alignment: .bottomLeading) {
                WidgetArtwork(item: item)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                Text(item.title).font(.system(size: 10, weight: .semibold)).lineLimit(1).padding(.horizontal, 6).padding(.bottom, 4)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.15)))
        }
    }

    private func row(_ item: WidgetItem) -> some View {
        Link(destination: item.link) {
            HStack(spacing: 12) {
                WidgetArtwork(item: item)
                    .frame(width: 76, height: 43)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text([item.caption, item.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.vertical, 6)
        }
    }

    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 26, height: 26)
            .background(.white.opacity(0.9), in: Circle())
    }
}

/// Backdrop when there is one, else the poster cropped from the top; a tinted fill when neither exists.
/// Always takes exactly the space it's offered.
struct WidgetArtwork: View {
    let item: WidgetItem

    var body: some View {
        ContinueWatchingView.background
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.25, green: 0.16, blue: 0.38), ContinueWatchingView.background],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipped()
    }

    private var image: UIImage? {
        for file in [item.backdropFile, item.imageFile].compactMap({ $0 }) {
            if let url = WidgetSnapshot.imageURL(file), let image = UIImage(contentsOfFile: url.path) { return image }
        }
        return nil
    }
}
