import AMDBCore
import AMDBKit
import SwiftUI

/// "Can't decide?" — a random well-rated pick for a mood.
struct SurpriseSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: SurpriseModel?
    @State private var kind: MediaKind = .movie
    @State private var mood: Mood = .anything

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Type", selection: $kind) {
                        Text("Movie").tag(MediaKind.movie)
                        Text("Series").tag(MediaKind.tv)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    FlowLayout(spacing: 8) {
                        ForEach(Mood.allCases) { option in
                            Button { mood = option } label: {
                                Text("\(option.emoji)  \(option.title)").font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .foregroundStyle(mood == option ? .black : .white)
                                    .background(mood == option ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 560)

                    result
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.sheet)
            .navigationTitle("Surprise me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationBackground(Theme.sheet)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            model = SurpriseModel(catalog: catalog)
            await model?.roll(kind: kind, mood: mood)
        }
        .onChange(of: kind) { roll() }
        .onChange(of: mood) { roll() }
    }

    @ViewBuilder private var result: some View {
        if let model, let pick = model.pick {
            VStack(alignment: .leading, spacing: 12) {
                RemoteImage(path: pick.backdropPath ?? pick.posterPath, size: "w780", seed: pick.title)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .center) { if model.isRolling { ProgressView().controlSize(.large) } }
                Text(pick.title).font(.title2.weight(.semibold))
                MetaLine(item: pick, detail: nil)
                if !pick.overview.isEmpty {
                    Text(pick.overview).font(.callout).foregroundStyle(.white.opacity(0.8)).lineLimit(4)
                }
                HStack(spacing: 10) {
                    Button {
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            router.open(pick)
                        }
                    } label: { Label("Open", systemImage: "info.circle") }
                    .buttonStyle(.primaryPill)
                    Button { roll() } label: { Label("Roll again", systemImage: "dice") }
                        .buttonStyle(.glassPill)
                    MyListButton(item: pick, iconOnly: true)
                }
            }
            .frame(maxWidth: 560)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .id(pick.id)
        } else if model?.isEmpty == true {
            Text("Nothing matched that mood. Try another one.").foregroundStyle(.secondary).padding(.top, 30)
        } else {
            ProgressView().padding(.top, 40)
        }
    }

    private func roll() {
        guard let model else { return }
        Task {
            await model.roll(kind: kind, mood: mood)
        }
    }
}
