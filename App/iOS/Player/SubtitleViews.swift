import AMDBCore
import AMDBKit
import SwiftUI

/// The line currently on screen; updated by the player's time observer.
@Observable @MainActor
final class SubtitleLine {
    var text: String?
    /// Where the picture is drawn inside the player (letterboxing excluded), so text sits on the video.
    var videoBounds: CGRect = .zero
}

/// OpenSubtitles text drawn over the video (inside AVKit's content overlay, below its controls).
struct SubtitleOverlayView: View {
    let line: SubtitleLine
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            let video = line.videoBounds.isEmpty ? CGRect(origin: .zero, size: proxy.size) : line.videoBounds
            let compact = video.height < 400
            VStack {
                Spacer()
                if let text = line.text {
                    Text(text)
                        .font(.system(size: compact ? 15 : (sizeClass == .compact ? 18 : 26), weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 16)
                        .padding(.bottom, max(proxy.size.height - video.maxY, 0) + video.height * 0.06)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Floating "Subtitles" button shown alongside AVKit's controls.
struct SubtitlesButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subtitles")
    }
}

/// The one subtitles menu: off, put.io's tracks, or an OpenSubtitles search; plus timing for what's showing.
struct SubtitleSheet: View {
    let finder: SubtitleFinder
    let onPicked: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let choice = finder.choice, !choice.isOff, finder.isShowing {
                    Section("Showing") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.release).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text("\(languageName(choice.language)) · \(choice.putioKey == nil ? "OpenSubtitles" : "put.io")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button { Task { await finder.shiftTiming(by: -0.5) } } label: {
                                Label("Earlier", systemImage: "minus").labelStyle(.iconOnly).frame(width: 36, height: 30)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Show subtitles earlier")
                            Spacer()
                            VStack(spacing: 2) {
                                Text(timing(choice.offset)).font(.headline.monospacedDigit())
                                Text("Timing").font(.caption2).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            Spacer()
                            Button { Task { await finder.shiftTiming(by: 0.5) } } label: {
                                Label("Later", systemImage: "plus").labelStyle(.iconOnly).frame(width: 36, height: 30)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Show subtitles later")
                        }
                    }
                }

                Section {
                    Button { Task { await finder.turnOff(); onPicked() } } label: {
                        HStack {
                            Text("Off").foregroundStyle(.primary)
                            Spacer()
                            if !finder.isShowing { Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.semibold) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    ForEach(finder.putioTracks) { track in
                        Button { Task { await pick(track) } } label: { putioRow(track) }
                            .buttonStyle(.plain)
                            .disabled(finder.loadingPutioKey != nil)
                    }
                } header: {
                    Text("On put.io")
                } footer: {
                    if finder.putioTracks.isEmpty { Text("put.io has no subtitles for this video. Search OpenSubtitles below.") }
                }

                if finder.canSearch {
                Section {
                    Picker("Language", selection: Binding(get: { finder.language }, set: { newValue in
                        finder.language = newValue
                        Task { await finder.search() }
                    })) {
                        ForEach(SettingsView.languages, id: \.code) { language in
                            Text(language.name).tag(SubtitleFinder.openSubtitlesCode(language.code))
                        }
                    }
                } footer: {
                    if let message = finder.message {
                        Text(message).foregroundStyle(Theme.poor)
                    }
                }

                Section {
                    if finder.isSearching {
                        HStack { ProgressView(); Text("Searching OpenSubtitles…").foregroundStyle(.secondary) }
                    } else if finder.searched, finder.results.isEmpty, finder.message == nil {
                        Text("No \(languageName(finder.language)) subtitles found for this video.").foregroundStyle(.secondary)
                    }
                    ForEach(finder.results) { result in
                        Button { Task { await pick(result) } } label: { row(result) }
                            .buttonStyle(.plain)
                            .disabled(finder.downloadingID != nil)
                    }
                } header: {
                    if !finder.results.isEmpty { Text("OpenSubtitles") }
                } footer: {
                    if let remaining = finder.remainingDownloads {
                        Text("\(remaining) OpenSubtitles downloads left today. Subtitles you've picked before don't count again.")
                    }
                }
                } else {
                    Section {
                        Text("Add an OpenSubtitles API key in Settings to search for more subtitles.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("OpenSubtitles") }
                }
            }
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { if finder.canSearch, !finder.searched { await finder.search() } }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }

    private func row(_ result: SubtitleResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.release).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    if result.hashMatch { tag("Matches this file", color: Theme.good) }
                    if result.trusted { tag("Trusted", color: .blue) }
                    if result.hearingImpaired { tag("SDH", color: .gray) }
                    if result.machineTranslated { tag("Machine translated", color: Theme.okay) }
                    Label(downloads(result.downloads), systemImage: "arrow.down.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if finder.downloadingID == result.fileID {
                ProgressView()
            } else if finder.isShowing, finder.choice?.putioKey == nil, finder.choice?.subtitleFileID == result.fileID {
                Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }

    private func putioRow(_ track: PutioSubtitle) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(track.language ?? track.name ?? "Subtitle").font(.subheadline).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    switch track.source {
                    case "mkv": tag("In the file", color: Theme.good)
                    case "folder": tag("Next to the file", color: .blue)
                    default: tag("Fetched by put.io", color: .gray)
                    }
                    if let name = track.name, name != track.language {
                        Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if finder.loadingPutioKey == track.key {
                ProgressView()
            } else if finder.isShowing, finder.choice?.putioKey == track.key {
                Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }

    private func pick(_ track: PutioSubtitle) async {
        await finder.choose(track)
        if finder.choice?.putioKey == track.key, finder.message == nil {
            onPicked()
            dismiss()
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .lineLimit(1)
    }

    private func pick(_ result: SubtitleResult) async {
        await finder.choose(result)
        if finder.choice?.subtitleFileID == result.fileID, finder.message == nil {
            onPicked()
            dismiss()
        }
    }

    private func languageName(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return SettingsView.languages.first { $0.code == base }?.name
            ?? Locale.current.localizedString(forLanguageCode: base) ?? code
    }

    private func timing(_ offset: Double) -> String {
        offset == 0 ? "In sync" : String(format: "%+.1fs", offset)
    }

    private func downloads(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }
}
