#if DEBUG
import SwiftUI
import WidgetKit

/// Debug-only: `-widgetPreview` overlays the Continue Watching widget, rendered from the published
/// App Group snapshot at iPhone widget sizes, so layout can be checked without the Home Screen.
struct WidgetGallery: View {
    static var isEnabled: Bool { CommandLine.arguments.contains("-widgetPreview") }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let items = WidgetSnapshot.load()?.continueWatching ?? []
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 20) {
                        tile(items, .systemSmall, width: 170, height: 170)
                        tile([], .systemSmall, width: 170, height: 170)
                    }
                    tile(items, .systemMedium, width: 364, height: 170)
                    tile(items, .systemLarge, width: 364, height: 382)
                }
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity)
            }
            .background(LinearGradient(colors: [.indigo, .orange.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
    }

    private func tile(_ items: [WidgetItem], _ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        ContinueWatchingView(items: items, family: family)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityIdentifier("widget-\(family)")
    }
}
#endif
