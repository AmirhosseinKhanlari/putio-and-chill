import AMDBCore
import AMDBKit
import Observation
import SwiftUI

/// One ChartModel per chart for the whole session, shared by the row and the full page.
@Observable @MainActor
final class ChartCenter {
    @ObservationIgnored private var models: [IMDbChart: ChartModel] = [:]

    func model(_ chart: IMDbChart, app: AppModel) -> ChartModel? {
        guard app.hasCharts, let catalog = app.catalog else { return nil }
        if let existing = models[chart] { return existing }
        let model = ChartModel(chart: chart, app: app, catalog: catalog)
        models[chart] = model
        return model
    }
}

/// Full-page ranked list for an IMDb chart.
struct ChartPage: View {
    let chart: IMDbChart
    @Environment(AppModel.self) private var app
    @Environment(ChartCenter.self) private var charts
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: ChartModel?

    var body: some View {
        let regular = sizeClass != .compact
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: regular ? 12 : 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("IMDB TOP 250").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text(chart.kind == .tv ? "TV Shows" : "Movies")
                        .font(.system(size: regular ? 54 : 38, weight: .ultraLight)).tracking(3)
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, regular ? 64 : 56)
                .padding(.bottom, 14)

                if let model {
                    if model.isLoading && model.entries.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if model.error != nil {
                        Text("Couldn't load the chart. Pull to retry.").foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(model.entries) { entry in
                        ChartListRow(model: model, entry: entry)
                    }
                    if !model.entries.isEmpty {
                        Text("Lists from Trakt").font(.caption2).foregroundStyle(.white.opacity(0.4)).padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 120)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .task {
            guard model == nil, let shared = charts.model(chart, app: app) else { return }
            model = shared
            await shared.load()
            if let first = shared.entries.first, let item = await shared.item(for: first) { ambient.focus(item) }
        }
    }

    private var subtitle: String {
        let count = model?.entries.count ?? 0
        return count > 0 ? "\(count) titles, ranked by IMDb users" : "Ranked by IMDb users"
    }
}

private struct ChartListRow: View {
    let model: ChartModel
    let entry: ChartEntry
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let regular = sizeClass != .compact
        let item = model.items[entry.id]
        Button {
            if let item { router.open(item) }
        } label: {
            HStack(spacing: regular ? 18 : 12) {
                Text("\(entry.rank)")
                    .font(.system(size: regular ? 40 : 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rankStyle)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(width: regular ? 76 : 44, alignment: .trailing)
                RemoteImage(path: item?.posterPath, size: "w185", seed: entry.title)
                    .frame(width: regular ? 84 : 58, height: regular ? 126 : 87)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(regular ? .title3.weight(.semibold) : .headline).lineLimit(2)
                    HStack(spacing: 8) {
                        if let year = entry.year { Text(String(year)) }
                        if let vote = item?.voteAverage, vote > 0 {
                            Label(String(format: "%.1f", vote), systemImage: "star.fill")
                        }
                        if let item, !app.library.matching(tmdbID: item.tmdbID).isEmpty {
                            Label("In put.io", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    if regular, let overview = item?.overview, !overview.isEmpty {
                        Text(overview).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(regular ? 14 : 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.lift)
        .task(id: entry.id) { await model.item(for: entry) }
        .accessibilityLabel("Number \(entry.rank), \(entry.title)")
    }

    /// Gold, silver and bronze for the podium; white for everyone else.
    private var rankStyle: AnyShapeStyle {
        let podium: [Int: (Color, Color)] = [
            1: (Color(red: 1.0, green: 0.86, blue: 0.4), Color(red: 0.85, green: 0.6, blue: 0.15)),
            2: (Color(red: 0.9, green: 0.92, blue: 0.95), Color(red: 0.6, green: 0.64, blue: 0.7)),
            3: (Color(red: 0.95, green: 0.68, blue: 0.45), Color(red: 0.7, green: 0.42, blue: 0.22)),
        ]
        if let (top, bottom) = podium[entry.rank] {
            return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(.white.opacity(0.85))
    }
}
