import AMDBCore
import AMDBKit
import SwiftUI

/// The whole put.io, like Files: browse folders, play videos, and rename, move, copy or delete anything.
/// Deleted items go to put.io's Trash (reachable from the top level).
struct FilesPage: View {
    let folder: FilesFolder
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(OfflineDownloader.self) private var downloader
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @AppStorage("filesSort") private var sortRaw = FileSort.name.rawValue
    @State private var model: FileBrowserModel?
    @State private var search: FileSearchModel?
    @State private var query = ""
    @State private var selecting = false
    @State private var selection = Set<Int64>()
    @State private var renaming: PutioFile?
    @State private var newName = ""
    @State private var askingFolderName = false
    @State private var folderName = ""
    @State private var destination: DestinationRequest?
    @State private var deleting: Set<Int64>?
    @State private var errorMessage: String?
    /// Folders whose videos are being looked up for Download All.
    @State private var gathering: Set<Int64> = []

    private var sort: FileSort { FileSort(rawValue: sortRaw) ?? .name }
    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: Metrics.gutter(sizeClass), bottom: 8, trailing: Metrics.gutter(sizeClass)))
            if isSearching {
                searchResults
            } else if let model {
                if !model.loaded {
                    HStack { ProgressView(); Text("Reading put.io…").foregroundStyle(.secondary) }.listRowBackground(Color.clear)
                } else if let message = model.errorMessage {
                    Text(message).foregroundStyle(Theme.poor).listRowBackground(Color.clear)
                } else if model.files.isEmpty {
                    Text("This folder is empty.").foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                ForEach(model.files) { file in row(file) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if selecting { selectionBar }
                Color.clear.frame(height: sizeClass == .compact ? Metrics.tabBarInset(sizeClass) : 8)
            }
        }
        .refreshable {
            await model?.load()
            await app.storage.refresh()
        }
        .task {
            guard model == nil, let putio = app.putio else { return }
            let browser = FileBrowserModel(folderID: folder.id, putio: putio, sort: sort)
            browser.onChange = { [app] in app.putioFilesChanged() }
            model = browser
            search = FileSearchModel(putio: putio)
            await browser.load()
            if folder.id == 0 { await app.storage.refresh() }
        }
        .onChange(of: sortRaw) { _, _ in model?.sort = sort }
        .task(id: query) {
            guard isSearching else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search?.search(query)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let file = renaming { run { try await model?.rename(file, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $askingFolderName) {
            TextField("Name", text: $folderName)
            Button("Create") { let name = folderName; run { try await model?.createFolder(named: name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In \(folder.id == 0 ? "your put.io" : folder.name).")
        }
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                guard let ids = deleting else { return }
                run {
                    try await model?.delete(ids)
                    endSelecting()
                    // Home and Library drop them now; whatever was inside deleted folders goes with the next refresh.
                    await app.library.forget(ids)
                }
            }
        } message: {
            Text("They stay in put.io's Trash until it's emptied, so you can still restore them.")
        }
        .sheet(item: $destination) { request in
            DestinationPicker(request: request) { parentID in
                run {
                    switch request.action {
                    case .move: try await model?.move(request.ids, to: parentID)
                    case .copy: try await model?.copy(request.ids, to: parentID)
                    }
                    endSelecting()
                    router.toast = "\(request.action == .move ? "Moved" : "Copied") \(request.ids.count) item\(request.ids.count == 1 ? "" : "s")"
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PUT.IO").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                Text(folder.name).font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(2)
                    .lineLimit(2)
                if let model, model.loaded {
                    Text(PutioFileStyle.summary(model.files)).font(.footnote).foregroundStyle(.white.opacity(0.55))
                }
                // Everything in this folder (a whole season pack) to this device.
                if folder.id != 0, let model, model.files.contains(where: { $0.isVideo || $0.isFolder }) {
                    Button { download(FilesFolderAsFile.make(folder)) } label: {
                        if gathering.contains(folder.id) {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Download All") }
                        } else {
                            Label("Download All", systemImage: "arrow.down.to.line")
                        }
                    }
                    .buttonStyle(.glassPill)
                    .padding(.top, 8)
                    .accessibilityLabel("Download all videos in \(folder.name) to this device")
                }
            }
            .padding(.top, 44)
            if folder.id == 0 {
                StorageMeter()
                trashLink
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search all of put.io", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassCapsule()
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(FileSort.allCases, id: \.rawValue) { Text(PutioFileStyle.sortTitle($0)).tag($0.rawValue) }
                    }
                    Button { folderName = ""; askingFolderName = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44).glassCapsule()
                        .contentShape(Circle())
                }
                .accessibilityLabel("Sort and new folder")
                Button(selecting ? "Done" : "Select") {
                    if selecting { endSelecting() } else { selecting = true }
                }
                .buttonStyle(.glassPill)
                .disabled(isSearching || (model?.files.isEmpty ?? true))
            }
        }
    }

    private var trashLink: some View {
        Button { router.openTrash() } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash").frame(width: 28)
                Text("Trash").font(.subheadline.weight(.semibold))
                Spacer()
                if app.storage.trashSize > 0 {
                    Text(Format.bytes(app.storage.trashSize)).font(.footnote).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .glassRounded(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .frame(maxWidth: 420)
        .accessibilityLabel(app.storage.trashSize > 0 ? "Trash, \(Format.bytes(app.storage.trashSize))" : "Trash")
    }

    // MARK: Rows

    @ViewBuilder private var searchResults: some View {
        let results = search?.results ?? []
        if search?.searching == true, results.isEmpty {
            HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }.listRowBackground(Color.clear)
        } else if results.isEmpty {
            Text("Nothing in your put.io matches \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
        ForEach(results) { file in
            FileRow(file: file, selected: nil, resume: resume(file)) { open(file) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter(sizeClass), bottom: 6, trailing: Metrics.gutter(sizeClass)))
        }
    }

    private func row(_ file: PutioFile) -> some View {
        HStack(spacing: 10) {
            FileRow(file: file, selected: selecting ? selection.contains(file.id) : nil, resume: resume(file)) {
                if selecting { toggle(file.id) } else { open(file) }
            }
            // Save to this device for offline viewing, with its progress (like episode rows).
            if file.isVideo, !selecting { DownloadButton(entry: entry(file), plain: true) }
            if file.isFolder, !selecting, (file.size ?? 1) > 0 { folderDownloadButton(file) }
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.08))
        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter(sizeClass), bottom: 6, trailing: Metrics.gutter(sizeClass)))
        .contextMenu { if !selecting { menu(file) } }
        .swipeActions(edge: .trailing) {
            if !selecting {
                Button(role: .destructive) { deleting = [file.id] } label: { Label("Delete", systemImage: "trash") }
                    .tint(Theme.poor)
                Button { destination = DestinationRequest(action: .move, ids: [file.id], source: folder.id) } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .leading) {
            if !selecting, file.isFolder || file.isVideo, OfflineDownloader.isSupported {
                Button { download(file) } label: { Label("Download", systemImage: "arrow.down.to.line") }
                    .tint(Theme.good)
            }
        }
    }

    @ViewBuilder private func menu(_ file: PutioFile) -> some View {
        if file.isVideo {
            Button { open(file) } label: { Label("Play", systemImage: "play.fill") }
            if OfflineDownloader.isSupported, app.downloads.record(fileID: file.id) == nil {
                Button { Task { await downloader.start(entry(file)) } } label: {
                    Label("Download to This Device", systemImage: "arrow.down.to.line")
                }
            }
        } else if file.isFolder {
            if OfflineDownloader.isSupported {
                Button { download(file) } label: { Label("Download All Videos", systemImage: "arrow.down.to.line") }
            }
        } else {
            Button { open(file) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        }
        if file.isVideo || file.isFolder {
            // Wrong title (or none) in the Library: pick the right one for this video, or everything in this folder.
            Button { router.fixMatch = file.isFolder ? .folder(file) : .video(file, folderName: folder.id == 0 ? nil : folder.name) } label: {
                Label("Fix Match…", systemImage: "wand.and.stars")
            }
        }
        Button { newName = file.name; renaming = file } label: { Label("Rename", systemImage: "pencil") }
        Button { destination = DestinationRequest(action: .move, ids: [file.id], source: folder.id) } label: {
            Label("Move", systemImage: "folder")
        }
        Button { destination = DestinationRequest(action: .copy, ids: [file.id], source: folder.id) } label: {
            Label("Copy", systemImage: "plus.square.on.square")
        }
        if !file.isFolder {
            Button { copyLink(file) } label: { Label("Copy Download Link", systemImage: "link") }
        }
        Divider()
        Button(role: .destructive) { deleting = [file.id] } label: { Label("Delete", systemImage: "trash") }
    }

    private var selectionBar: some View {
        let none = selection.isEmpty
        return HStack(spacing: 8) {
            Text(none ? "Select items" : "\(selection.count) selected").font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            barButton("Move", "folder") { destination = DestinationRequest(action: .move, ids: selection, source: folder.id) }
            barButton("Copy", "plus.square.on.square") {
                destination = DestinationRequest(action: .copy, ids: selection, source: folder.id)
            }
            barButton("Delete", "trash", tint: Theme.poor) { deleting = selection }
        }
        .disabled(none)
        .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 4)
        .glassCapsule()
        .frame(maxWidth: 520)
        .padding(.horizontal, Metrics.gutter(sizeClass))
    }

    private func barButton(_ title: String, _ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).foregroundStyle(selection.isEmpty ? .white.opacity(0.3) : tint)
                .frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Actions

    private var deleteTitle: String {
        let count = deleting?.count ?? 0
        if count == 1, let id = deleting?.first, let file = (model?.files ?? []).first(where: { $0.id == id }) {
            return "Delete \u{201C}\(file.name)\u{201D}?"
        }
        return "Delete \(count) items?"
    }

    private func toggle(_ id: Int64) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private func entry(_ file: PutioFile) -> LibraryEntry {
        app.library.entries.first { $0.id == file.id } ?? LibraryEntry(file: file, match: nil, folderName: nil)
    }

    private func resume(_ file: PutioFile) -> Int {
        file.isVideo ? app.library.resumeSeconds(for: entry(file)) : 0
    }

    private func open(_ file: PutioFile) {
        if file.isFolder {
            router.openFolder(FilesFolder(id: file.id, name: file.name))
        } else if file.isVideo {
            let entry = entry(file)
            router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
        } else {
            Task {
                guard let url = try? await app.putio?.originalURL(fileID: file.id) else {
                    errorMessage = "Couldn't get a link to this file from put.io."
                    return
                }
                openURL(url)
            }
        }
    }

    /// A video, or every video in a folder (a whole season pack), saved to this device.
    private func folderDownloadButton(_ folder: PutioFile) -> some View {
        Button { download(folder) } label: {
            if gathering.contains(folder.id) {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                Image(systemName: "arrow.down.to.line.circle").font(.system(size: 28, weight: .light))
            }
        }
        .buttonStyle(.lift)
        .accessibilityLabel("Download all videos in \(folder.name)")
    }

    private func download(_ file: PutioFile) {
        guard OfflineDownloader.isSupported else {
            errorMessage = "Apple's offline video downloads don't run in the Simulator. On your iPad or iPhone this saves the videos for offline viewing."
            return
        }
        guard file.isFolder else {
            Task { await downloader.start(entry(file)) }
            return
        }
        guard !gathering.contains(file.id) else { return }
        gathering.insert(file.id)
        Task {
            defer { gathering.remove(file.id) }
            guard let putio = app.putio, let videos = try? await PlaybackResolver.videos(in: file.id, putio: putio) else {
                errorMessage = "Couldn't read this folder from put.io."
                return
            }
            let missing = videos.filter { app.downloads.record(fileID: $0.id) == nil }
            router.toast = missing.isEmpty ? "Already on this device"
                : "Downloading \(missing.count) video\(missing.count == 1 ? "" : "s")"
            for video in missing { await downloader.start(entry(video)) }
        }
    }

    private func copyLink(_ file: PutioFile) {
        Task {
            guard let url = try? await app.putio?.originalURL(fileID: file.id) else {
                errorMessage = "Couldn't get a link to this file from put.io."
                return
            }
            UIPasteboard.general.url = url
            router.toast = "Download link copied"
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch {
                errorMessage = "put.io didn't accept that. Check your connection and try again."
                await model?.load()
            }
        }
    }
}

/// One file or folder: icon or video frame, name, size and date.
private struct FileRow: View {
    let file: PutioFile
    /// nil when not selecting.
    let selected: Bool?
    let resume: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Theme.good : .white.opacity(0.4))
                }
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(PutioFileStyle.detail(file))
                        if resume >= 30 { Text("· \(Format.clock(resume)) watched") }
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if file.isFolder, selected == nil {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .accessibilityLabel(file.name)
        .accessibilityValue(selected == true ? "Selected" : "")
        .accessibilityHint(file.isFolder ? "Opens the folder" : file.isVideo ? "Plays the video" : "Opens the file")
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        if file.isVideo, let screenshot = file.screenshot.flatMap(URL.init(string:)) {
            AsyncImage(url: screenshot) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                icon
            }
            .frame(width: 64, height: 40)
            .clipShape(shape)
        } else {
            icon.frame(width: 64, height: 40)
        }
    }

    private var icon: some View {
        Image(systemName: PutioFileStyle.symbol(file.fileType))
            .font(.title3)
            .foregroundStyle(file.isFolder ? Color(red: 0.55, green: 0.7, blue: 1) : .white.opacity(0.75))
            .frame(width: 64, height: 40)
            .background(.white.opacity(file.isFolder ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Move / copy destination

/// Pick where to move or copy: browse folders, make a new one, then "Move Here" / "Copy Here".
private struct DestinationPicker: View {
    let request: DestinationRequest
    let onPick: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DestinationLevel(folder: .root, request: request) { id in
                dismiss()
                onPick(id)
            }
        }
        .presentationBackground(Theme.sheet)
    }
}

private struct DestinationLevel: View {
    let folder: FilesFolder
    let request: DestinationRequest
    let onPick: (Int64) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: FileBrowserModel?
    @State private var askingName = false
    @State private var name = ""

    private var verb: String { request.action == .move ? "Move" : "Copy" }
    private var canPick: Bool { !(request.action == .move && folder.id == request.source) && !request.ids.contains(folder.id) }

    var body: some View {
        List {
            if let model {
                if !model.loaded { ProgressView() }
                if model.loaded, model.folders.isEmpty { Text("No folders here").foregroundStyle(.secondary) }
                ForEach(model.folders) { sub in
                    // A folder can't go inside itself.
                    if request.ids.contains(sub.id) {
                        Label(sub.name, systemImage: "folder").foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            DestinationLevel(folder: FilesFolder(id: sub.id, name: sub.name), request: request, onPick: onPick)
                        } label: {
                            Label(sub.name, systemImage: "folder.fill")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sheet)
        .navigationTitle(folder.id == 0 ? "Your put.io" : folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folder.id == 0 {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { name = ""; askingName = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Spacer()
                Button("\(verb) Here") { onPick(folder.id) }
                    .fontWeight(.semibold)
                    .disabled(!canPick)
            }
        }
        .alert("New Folder", isPresented: $askingName) {
            TextField("Name", text: $name)
            Button("Create") { let name = name; Task { try? await model?.createFolder(named: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            guard model == nil, let putio = app.putio else { return }
            let level = FileBrowserModel(folderID: folder.id, putio: putio)
            level.onChange = { [app] in app.putioFilesChanged() }
            model = level
            await level.load()
        }
    }

}

// MARK: Trash

/// put.io's Trash: restore or delete for good; Empty Trash frees the space.
struct TrashPage: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: TrashModel?
    @State private var confirmEmpty = false
    @State private var forever: Set<Int64>?
    @State private var errorMessage: String?

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PUT.IO").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text("Trash").font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(2)
                    if let model, model.loaded {
                        Text(model.files.isEmpty ? "Empty" : "\(model.files.count) item\(model.files.count == 1 ? "" : "s") · \(Format.bytes(model.size))")
                            .font(.footnote).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.top, 44)
                Text("Deleted files wait here before put.io removes them for good. Empty the trash to free the space now.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.55))
                if let model, !model.files.isEmpty {
                    Button(role: .destructive) { confirmEmpty = true } label: { Label("Empty Trash", systemImage: "trash.slash") }
                        .buttonStyle(.glassPill)
                        .tint(Theme.poor)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: Metrics.gutter(sizeClass), bottom: 8, trailing: Metrics.gutter(sizeClass)))
            if let model {
                if !model.loaded { ProgressView().listRowBackground(Color.clear) }
                if let message = model.errorMessage { Text(message).foregroundStyle(Theme.poor).listRowBackground(Color.clear) }
                ForEach(model.files) { file in
                    HStack(spacing: 14) {
                        Image(systemName: PutioFileStyle.symbol(file.fileType)).font(.title3).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44, height: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(PutioFileStyle.detail(file)).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Menu {
                            Button { run { try await model.restore([file.id]) } } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            Button(role: .destructive) { forever = [file.id] } label: { Label("Delete Forever", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("More for \(file.name)")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.08))
                    .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter(sizeClass), bottom: 6, trailing: Metrics.gutter(sizeClass)))
                    .swipeActions(edge: .leading) {
                        Button { run { try await model.restore([file.id]) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            .tint(Theme.good)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { forever = [file.id] } label: { Label("Delete Forever", systemImage: "trash") }
                            .tint(Theme.poor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: sizeClass == .compact ? Metrics.tabBarInset(sizeClass) : 8)
        }
        .refreshable { await model?.load() }
        .task {
            guard model == nil, let putio = app.putio else { return }
            let trash = TrashModel(putio: putio)
            trash.onChange = { [app] in app.putioFilesChanged() }
            model = trash
            await trash.load()
        }
        .alert("Empty the trash?", isPresented: $confirmEmpty) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) {
                run {
                    try await model?.empty()
                    router.toast = "Trash emptied"
                }
            }
        } message: {
            Text("Everything in it is deleted for good (\(Format.bytes(model?.size ?? 0))). This can't be undone.")
        }
        .alert("Delete forever?", isPresented: Binding(get: { forever != nil }, set: { if !$0 { forever = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Forever", role: .destructive) {
                guard let ids = forever else { return }
                run { try await model?.deleteForever(ids) }
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch {
                errorMessage = "put.io didn't accept that. Check your connection and try again."
                await model?.load()
            }
        }
    }
}

/// The folder on screen, as the put.io folder Download All reads.
private enum FilesFolderAsFile {
    static func make(_ folder: FilesFolder) -> PutioFile { PutioFile(id: folder.id, name: folder.name, fileType: "FOLDER") }
}
