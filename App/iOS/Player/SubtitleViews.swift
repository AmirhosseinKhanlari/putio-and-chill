import AMDBCore
import AMDBKit
import SwiftUI

/// Subtitles drawn on the picture (put.io or OpenSubtitles, picked in the subtitles menu; or a track inside the file
/// on the built-in player). Sits near the bottom of the video and moves up while the controls are showing.
struct SubtitleOverlayView: View {
    let finder: SubtitleFinder
    let engine: PlayerEngine
    let videoRect: CGRect
    var style: SubtitleStyle = .standard
    /// Distance to keep clear of the screen bottom (the control bar), 0 when controls are hidden.
    let liftedBy: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let compact = videoRect.height < 400
            if case let .images(images)? = engine.embeddedSubtitle {
                // Picture subtitles (Blu-ray, DVD) go where the disc placed them on the video.
                ForEach(images.indices, id: \.self) { index in
                    let frame = images[index].frame
                    Image(decorative: images[index].image, scale: 1)
                        .resizable()
                        .frame(width: videoRect.width * frame.width, height: videoRect.height * frame.height)
                        .position(x: videoRect.minX + videoRect.width * frame.midX, y: videoRect.minY + videoRect.height * frame.midY)
                }
            } else {
                VStack {
                    Spacer()
                    if let text = currentText {
                        StyledSubtitleText(text: text, style: style, compact: compact)
                            .padding(.horizontal, 24)
                            .padding(.bottom, max(proxy.size.height - videoRect.maxY + videoRect.height * 0.06, liftedBy))
                            .animation(.easeInOut(duration: 0.2), value: liftedBy)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    private var currentText: String? {
        if case let .text(text)? = engine.embeddedSubtitle { return text }
        // On AirPlay the TV draws this subtitle from the stream: not twice.
        if engine.airPlaySubtitleRoute.drawnByReceiver { return nil }
        return engine.embeddedSubtitleID == nil ? finder.text(at: engine.position) : nil
    }
}

/// The one subtitles menu: off, put.io's tracks, or an OpenSubtitles search; plus timing for what's showing.
struct SubtitleSheet: View {
    let finder: SubtitleFinder
    var engine: PlayerEngine?
    var style: Binding<SubtitleStyle>?
    let onPicked: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // AirPlay: the TV draws subtitles in its own caption style; what timing does there.
                if let engine, let note = engine.airPlaySubtitleNote ?? engine.airPlayNotice {
                    Section {
                        Label(note, systemImage: "airplayvideo")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: {
                        Text("AirPlay")
                    }
                }
                if let engine, engine.audioTracks.count > 1 {
                    Section("Audio") {
                        ForEach(engine.audioTracks) { track in
                            Button { engine.selectAudio(id: track.id) } label: {
                                HStack {
                                    Text(track.name).foregroundStyle(.primary)
                                    Spacer()
                                    if engine.currentAudioID == track.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.semibold)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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
                    if let style {
                        NavigationLink { SubtitleStyleEditor(style: style) } label: {
                            LabeledContent("Style", value: Self.summary(style.wrappedValue))
                        }
                    }
                    Button { Task { engine?.selectEmbeddedSubtitle(id: nil); await finder.turnOff(); onPicked() } } label: {
                        HStack {
                            Text("Off").foregroundStyle(.primary)
                            Spacer()
                            if !finder.isShowing, engine?.embeddedSubtitleID == nil {
                                Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Tracks inside the file itself, which the built-in player reads (picture subtitles included).
                if let engine, !engine.embeddedSubtitles.isEmpty {
                    Section {
                        ForEach(engine.embeddedSubtitles) { track in
                            Button {
                                Task {
                                    await finder.turnOff()
                                    engine.selectEmbeddedSubtitle(id: track.id)
                                    onPicked()
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.name).font(.subheadline).foregroundStyle(.primary)
                                        if track.isImage {
                                            Text("Picture subtitles: shown as in the file").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if engine.embeddedSubtitleID == track.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.good).fontWeight(.semibold)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("In the File")
                    }
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
            .navigationTitle((engine?.audioTracks.count ?? 0) > 1 ? "Audio & Subtitles" : "Subtitles")
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

    static func summary(_ style: SubtitleStyle) -> String {
        let size = ["small": "Small", "medium": "Medium", "large": "Large", "extraLarge": "Extra large"][style.size.rawValue] ?? ""
        let background = ["none": "no box", "translucent": "see-through box", "solid": "solid box"][style.background.rawValue] ?? ""
        return "\(size), \(background)"
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
        engine?.selectEmbeddedSubtitle(id: nil)
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
        engine?.selectEmbeddedSubtitle(id: nil)
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
