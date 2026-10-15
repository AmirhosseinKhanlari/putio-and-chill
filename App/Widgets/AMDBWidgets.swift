#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import SwiftUI
import WidgetKit

@main
struct AMDBWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        #if !targetEnvironment(macCatalyst)
        // iPhone and iPad only: Live Activities and Control Center controls don't exist on the Mac.
        TransferLiveActivity()
        if #available(iOS 18.0, *) { SurpriseControl() }
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
// MARK: Control Center

/// A Control Center / Lock Screen / Action button control that opens Surprise Me.
@available(iOS 18.0, *)
struct SurpriseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.amdb.surprise") {
            ControlWidgetButton(action: OpenSurpriseIntent()) {
                Label("Surprise Me", systemImage: "dice")
            }
        }
        .displayName("Surprise Me")
        .description("Pick a mood and get a great movie or series.")
    }
}

#endif

// MARK: Continue Watching

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let items: [WidgetItem]
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: .now, items: [
            WidgetItem(id: "p", title: "Interstellar", subtitle: "Resume 1:12:40", caption: "2014", imageFile: nil,
                       link: URL(string: "amdb://library")!),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        let items = WidgetSnapshot.load()?.continueWatching ?? []
        completion(ContinueWatchingEntry(date: .now, items: items.isEmpty ? placeholder(in: context).items : items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        let entry = ContinueWatchingEntry(date: .now, items: WidgetSnapshot.load()?.continueWatching ?? [])
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingEntryView(entry: entry)
                .containerBackground(ContinueWatchingView.background, for: .widget)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct ContinueWatchingEntryView: View {
    let entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ContinueWatchingView(items: entry.items, family: family)
    }
}

#if !targetEnvironment(macCatalyst)
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
#endif
