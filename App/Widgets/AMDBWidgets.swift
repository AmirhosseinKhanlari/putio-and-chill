import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AMDBWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        TransferLiveActivity()
    }
}

// MARK: Continue Watching

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let items: [WidgetItem]
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: .now, items: [
            WidgetItem(id: "p", title: "Interstellar", subtitle: "Resume 1:12:40", imageFile: nil, link: URL(string: "amdb://library")!),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        completion(ContinueWatchingEntry(date: .now, items: WidgetSnapshot.load()?.continueWatching ?? placeholder(in: context).items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        let entry = ContinueWatchingEntry(date: .now, items: WidgetSnapshot.load()?.continueWatching ?? [])
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.12, green: 0.08, blue: 0.2), Color(red: 0.03, green: 0.03, blue: 0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct ContinueWatchingView: View {
    let entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let count = family == .systemSmall ? 1 : (family == .systemMedium ? 3 : 6)
        let items = Array(entry.items.prefix(count))
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "play.rectangle.on.rectangle").font(.title2)
                Text("Nothing in progress").font(.caption).foregroundStyle(.secondary)
            }
            .widgetURL(URL(string: "amdb://library"))
        } else if family == .systemSmall, let item = items.first {
            ZStack(alignment: .bottomLeading) {
                poster(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.caption.weight(.bold)).lineLimit(2)
                    Label(item.subtitle, systemImage: "play.fill").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
                .padding(10)
            }
            .foregroundStyle(.white)
            .widgetURL(item.link)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue Watching").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(items) { item in
                        Link(destination: item.link) {
                            VStack(alignment: .leading, spacing: 3) {
                                poster(item).aspectRatio(2 / 3, contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(item.subtitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private func poster(_ item: WidgetItem) -> some View {
        if let file = item.imageFile, let url = WidgetSnapshot.imageURL(file), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Text(item.title).font(.caption2.weight(.bold)).multilineTextAlignment(.center).padding(4)
            }
        }
    }
}

// MARK: Transfer Live Activity

struct TransferLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            HStack(spacing: 14) {
                ring(context.state, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    Text(context.state.isReady ? "Ready to watch on put.io" : context.state.detail)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !context.state.isReady {
                        ProgressView(value: Double(context.state.percent), total: 100).tint(.white)
                    }
                }
                if context.state.isReady {
                    Image(systemName: "play.circle.fill").font(.largeTitle)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.07, green: 0.06, blue: 0.1))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(context.state.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ring(context.state, size: 38).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isReady ? "Ready" : "\(context.state.percent)%").font(.title3.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isReady ? "Tap to watch" : context.state.detail).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                ring(context.state, size: 18)
            } compactTrailing: {
                Text(context.state.isReady ? "▶" : "\(context.state.percent)%").font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                ring(context.state, size: 18)
            }
            .widgetURL(context.state.link)
        }
    }

    private func ring(_ state: TransferActivityAttributes.ContentState, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: size / 9)
            Circle().trim(from: 0, to: state.isReady ? 1 : CGFloat(state.percent) / 100)
                .stroke(state.isReady ? Color.green : .white, style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if state.isReady { Image(systemName: "checkmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.green) }
        }
        .frame(width: size, height: size)
    }
}
