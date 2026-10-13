import AMDBCore
import AMDBKit
import SwiftUI

/// A franchise in release order ("watch in order").
struct CollectionPage: View {
    let collectionID: Int
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var detail: CollectionDetail?
    @State private var failed = false

    var body: some View {
        let regular = sizeClass != .compact
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if let detail {
                    ZStack(alignment: .bottomLeading) {
                        RemoteImage(path: detail.backdropPath, size: "w1280", seed: detail.name)
                            .frame(height: regular ? 440 : 300)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("COLLECTION").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.7))
                            Text(detail.name.replacingOccurrences(of: " Collection", with: "").uppercased())
                                .font(.system(size: regular ? 52 : 32, weight: .ultraLight)).tracking(regular ? 4 : 2)
                                .lineLimit(2).minimumScaleFactor(0.6)
                            Text("\(detail.parts.count) titles · watch in release order")
                                .font(.footnote).foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(.horizontal, Metrics.gutter(sizeClass))
                        .padding(.bottom, 12)
                    }
                    if !detail.overview.isEmpty {
                        Text(detail.overview).font(.callout).foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(.horizontal, Metrics.gutter(sizeClass))
                    }
                    VStack(spacing: regular ? 12 : 8) {
                        ForEach(Array(detail.parts.enumerated()), id: \.element.id) { index, item in
                            CollectionRow(index: index + 1, item: item)
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                } else if failed {
                    Text("Couldn't load this collection.").foregroundStyle(.secondary).padding(.top, 120).frame(maxWidth: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 160)
                }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(edges: .top)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .task {
            guard detail == nil, let catalog = app.catalog else { return }
            do {
                let loaded = try await catalog.collection(id: collectionID)
                detail = loaded
                ambient.focus(path: loaded.backdropPath, seed: loaded.name)
            } catch {
                failed = true
            }
        }
    }
}

private struct CollectionRow: View {
    let index: Int
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let regular = sizeClass != .compact
        Button { router.open(item) } label: {
            HStack(spacing: regular ? 18 : 12) {
                Text("\(index)")
                    .font(.system(size: regular ? 34 : 24, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: regular ? 52 : 34, alignment: .trailing)
                RemoteImage(path: item.posterPath, size: "w185", seed: item.title)
                    .frame(width: regular ? 76 : 56, height: regular ? 114 : 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(regular ? .title3.weight(.semibold) : .headline).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(item.year.map(String.init) ?? "Upcoming")
                        if let vote = item.voteAverage, vote > 0 { Label(String(format: "%.1f", vote), systemImage: "star.fill") }
                        if !app.library.matching(tmdbID: item.tmdbID).isEmpty {
                            Label("In put.io", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
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
        .accessibilityLabel("\(index). \(item.title)")
    }
}
