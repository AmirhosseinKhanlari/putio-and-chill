import AMDBCore
import AMDBKit
import SwiftUI

struct ReadyBanner: View {
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let banner = router.banner {
            let transfer = banner.transfer
            HStack(spacing: 12) {
                RemoteImage(path: transfer.pending.posterPath, size: "w185", seed: transfer.pending.title)
                    .frame(width: 36, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.pending.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    switch banner {
                    case .ready: Text("Ready to watch").font(.caption).foregroundStyle(.white.opacity(0.7))
                    case .failed: Text(failureText(transfer)).font(.caption).foregroundStyle(Theme.poor).lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                if case .ready = banner {
                    Button {
                        router.play(transfer)
                        router.banner = nil
                    } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.primaryPill)
                } else if transfer.pending.tmdbID > 0 {
                    // The title page shows what went wrong and opens Versions from there.
                    Button {
                        let p = transfer.pending
                        router.showTitle(CatalogItem(tmdbID: p.tmdbID, mediaType: p.kind, title: p.title,
                                                     posterPath: p.posterPath, backdropPath: p.backdropPath))
                        router.banner = nil
                    } label: { Label("Versions", systemImage: "square.stack.3d.up") }
                    .buttonStyle(.primaryPill)
                    .accessibilityLabel("Choose Another Version")
                }
                Button { withAnimation { router.banner = nil } } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .glassRounded(20)
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.top, sizeClass == .compact ? 8 : 72)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(for: .seconds(8))
                if router.banner?.id == banner.id { withAnimation { router.banner = nil } }
            }
        }
    }

    private func failureText(_ transfer: TrackedTransfer) -> String {
        if case let .failed(message) = transfer.phase { return message }
        return "Transfer failed"
    }
}
