import AMDBCore
import AMDBKit
import SwiftUI

/// "IMDb Top 250" row: big rank numerals beside posters, plus a See All grid.
struct ChartRowView: View {
    let model: ChartModel
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showAll = false

    var body: some View {
        let width = Metrics.poster(sizeClass)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.chart.title).font(.title3.weight(.semibold))
                Spacer()
                if !model.entries.isEmpty {
                    Button("See all \(model.entries.count)") { showAll = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))

            if model.isLoading && model.entries.isEmpty {
                ProgressView().frame(height: width * 1.5).frame(maxWidth: .infinity)
            } else if model.error != nil {
                Text("Couldn't load the chart.").font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.gutter(sizeClass))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 4) {
                    ForEach(model.entries.prefix(20)) { entry in
                        RankedPoster(model: model, entry: entry, width: width)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
        .sheet(isPresented: $showAll) { ChartGridSheet(model: model) }
    }
}

private struct RankedPoster: View {
    let model: ChartModel
    let entry: ChartEntry
    let width: CGFloat
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            if let item = model.items[entry.id] { router.open(item) }
        } label: {
            HStack(alignment: .bottom, spacing: -width * 0.18) {
                Text("\(entry.rank)")
                    .font(.system(size: width * 0.8, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .frame(minWidth: width * 0.45)
                    .offset(y: width * 0.12)
                ChartPoster(model: model, entry: entry, width: width)
            }
        }
        .buttonStyle(.lift)
        .accessibilityLabel("Number \(entry.rank), \(entry.title)")
    }
}

struct ChartPoster: View {
    let model: ChartModel
    let entry: ChartEntry
    let width: CGFloat

    var body: some View {
        let item = model.items[entry.id]
        RemoteImage(path: item?.posterPath, size: "w342", seed: entry.title)
            .frame(width: width, height: width * 1.5)
            .overlay(alignment: .bottomLeading) {
                if item?.posterPath == nil {
                    Text(entry.title).font(.caption.weight(.bold)).padding(8).shadow(radius: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            .task(id: entry.id) { await model.item(for: entry) }
    }
}

private struct ChartGridSheet: View {
    let model: ChartModel
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let width = Metrics.poster(sizeClass)
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 20) {
                    ForEach(model.entries) { entry in
                        Button {
                            guard let item = model.items[entry.id] else { return }
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                router.open(item)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ChartPoster(model: model, entry: entry, width: width)
                                    .overlay(alignment: .topLeading) {
                                        Text("#\(entry.rank)").font(.caption.weight(.heavy))
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(.black.opacity(0.65), in: Capsule())
                                            .padding(6)
                                    }
                                Text(entry.title).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                if let year = entry.year {
                                    Text(String(year)).font(.caption2).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            .frame(width: width, alignment: .leading)
                        }
                        .buttonStyle(.lift)
                    }
                }
                .padding(Metrics.gutter(sizeClass))
            }
            .background(Theme.sheet)
            .navigationTitle(model.chart.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationBackground(Theme.sheet)
    }
}
