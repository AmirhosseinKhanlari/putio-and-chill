import AMDBCore
import AMDBKit
import SwiftUI

/// The whole put.io on the TV: open folders, play videos; hold Select on anything to rename, move, copy or delete it.
struct TVFilesView: View {
    let folder: FilesFolder
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @AppStorage("filesSort") private var sortRaw = FileSort.name.rawValue
    @State private var model: FileBrowserModel?
    @State private var renaming: PutioFile?
    @State private var newName = ""
    @State private var askingFolderName = false
    @State private var folderName = ""
    @State private var destination: DestinationRequest?
    @State private var deleting: PutioFile?
    @State private var notice: String?

    private var sort: FileSort { FileSort(rawValue: sortRaw) ?? .name }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                TVPageHeader(title: folder.id == 0 ? "Files" : folder.name, subtitle: subtitle)
                HStack(spacing: 16) {
                    ForEach(FileSort.allCases, id: \.rawValue) { option in
                        Button(PutioFileStyle.sortTitle(option)) { sortRaw = option.rawValue }.tvChip(selected: sort == option)
                    }
                    Button { folderName = ""; askingFolderName = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        .tvPill()
                    if folder.id == 0 {
                        Button { router.open(.trash) } label: {
                            Label(app.storage.trashSize > 0 ? "Trash · \(Format.bytes(app.storage.trashSize))" : "Trash",
                                  systemImage: "trash")
                        }
                        .tvPill()
                    }
                }
                .focusSection()
                if let notice { Text(notice).font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText) }
                if let model {
                    if !model.loaded {
                        ProgressView()
                    } else if let message = model.errorMessage {
                        Text(message).foregroundStyle(TVMetrics.secondaryText)
                    } else if model.files.isEmpty {
                        Text("This folder is empty.").foregroundStyle(TVMetrics.secondaryText)
                    }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.files) { file in row(file) }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
        .tvPageBackground()
        .task {
            guard model == nil, let putio = app.putio else { return }
            let browser = FileBrowserModel(folderID: folder.id, putio: putio, sort: sort)
            browser.onChange = { [app] in app.putioFilesChanged() }
            model = browser
            await browser.load()
            if folder.id == 0 { await app.storage.refresh() }
        }
        .onChange(of: sortRaw) { _, _ in model?.sort = sort }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let file = renaming { run("Renamed.") { try await model?.rename(file, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $askingFolderName) {
            TextField("Name", text: $folderName)
            Button("Create") { let name = folderName; run(nil) { try await model?.createFolder(named: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let file = deleting else { return }
                run("Moved to put.io's Trash.") {
                    try await model?.delete([file.id])
                    await app.library.forget([file.id])
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in put.io's Trash until it's emptied, so you can still restore it.")
        }
        .sheet(item: $destination) { request in
            TVDestinationPicker(request: request) { parentID in
                destination = nil
                run(request.action == .move ? "Moved." : "Copied.") {
                    switch request.action {
                    case .move: try await model?.move(request.ids, to: parentID)
                    case .copy: try await model?.copy(request.ids, to: parentID)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model, model.loaded { parts.append(PutioFileStyle.summary(model.files)) }
        if folder.id == 0, let disk = app.storage.disk { parts.append("\(Format.bytes(disk.avail)) free") }
        parts.append("Hold Select for more")
        return parts.joined(separator: " · ")
    }

    private func row(_ file: PutioFile) -> some View {
        Button { open(file) } label: {
            HStack(spacing: 24) {
                Image(systemName: PutioFileStyle.symbol(file.fileType)).font(.system(size: 30)).frame(width: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                    Text(PutioFileStyle.detail(file)).font(.system(size: 20)).opacity(0.7)
                }
                Spacer(minLength: 0)
                if file.isFolder { Image(systemName: "chevron.right").font(.system(size: 22, weight: .semibold)).opacity(0.5) }
            }
        }
        .tvRow()
        .contextMenu {
            if file.isVideo { Button("Play") { open(file) } }
            Button("Rename") { newName = file.name; renaming = file }
            Button("Move…") { destination = DestinationRequest(action: .move, ids: [file.id], source: folder.id) }
            Button("Copy…") { destination = DestinationRequest(action: .copy, ids: [file.id], source: folder.id) }
            Button("Delete", role: .destructive) { deleting = file }
        }
    }

    private func open(_ file: PutioFile) {
        if file.isFolder {
            router.open(.files(FilesFolder(id: file.id, name: file.name)))
        } else if file.isVideo {
            let entry = app.library.entries.first { $0.id == file.id } ?? LibraryEntry(file: file, match: nil, folderName: nil)
            router.play(entry, from: app.library.resumeSeconds(for: entry))
        } else {
            notice = "\u{201C}\(file.name)\u{201D} can't be opened on Apple TV. Hold Select to move, rename or delete it."
        }
    }

    private func run(_ success: String?, _ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
                notice = success
            } catch {
                notice = "put.io didn't accept that. Check your connection and try again."
                await model?.load()
            }
        }
    }
}

/// Where to move or copy something: open folders, then "Move Here" / "Copy Here".
private struct TVDestinationPicker: View {
    let request: DestinationRequest
    let onPick: (Int64) -> Void

    var body: some View {
        NavigationStack {
            TVDestinationLevel(folder: .root, request: request, onPick: onPick)
        }
    }
}

private struct TVDestinationLevel: View {
    let folder: FilesFolder
    let request: DestinationRequest
    let onPick: (Int64) -> Void
    @Environment(AppModel.self) private var app
    @State private var model: FileBrowserModel?

    private var verb: String { request.action == .move ? "Move" : "Copy" }
    private var canPick: Bool { !(request.action == .move && folder.id == request.source) && !request.ids.contains(folder.id) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                TVPageHeader(title: "\(verb) to \(folder.id == 0 ? "Your put.io" : folder.name)")
                Button { onPick(folder.id) } label: { Label("\(verb) Here", systemImage: "checkmark.circle.fill") }
                    .tvPill()
                    .disabled(!canPick)
                if let model {
                    if !model.loaded { ProgressView() }
                    ForEach(model.folders.filter { !request.ids.contains($0.id) }) { sub in
                        NavigationLink {
                            TVDestinationLevel(folder: FilesFolder(id: sub.id, name: sub.name), request: request, onPick: onPick)
                        } label: {
                            Label(sub.name, systemImage: "folder.fill").font(.system(size: 26, weight: .semibold))
                        }
                        .tvRow()
                    }
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
        .tvPageBackground()
        .task {
            guard model == nil, let putio = app.putio else { return }
            let level = FileBrowserModel(folderID: folder.id, putio: putio)
            model = level
            await level.load()
        }
    }
}

/// put.io's Trash on the TV: Restore, Delete Forever, Empty Trash.
struct TVTrashView: View {
    @Environment(AppModel.self) private var app
    @State private var model: TrashModel?
    @State private var confirmEmpty = false
    @State private var notice: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                TVPageHeader(title: "Trash", subtitle: subtitle)
                if let model, !model.files.isEmpty {
                    Button { confirmEmpty = true } label: { Label("Empty Trash", systemImage: "trash.slash") }
                        .tvPill()
                        .focusSection()
                }
                if let notice { Text(notice).font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText) }
                if let model {
                    if !model.loaded { ProgressView() }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.files) { file in
                            Button {} label: {
                                HStack(spacing: 24) {
                                    Image(systemName: PutioFileStyle.symbol(file.fileType)).font(.system(size: 30)).frame(width: 50)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                                        Text(PutioFileStyle.detail(file)).font(.system(size: 20)).opacity(0.7)
                                    }
                                }
                            }
                            .tvRow()
                            .contextMenu {
                                Button("Restore") { run("Restored.") { try await model.restore([file.id]) } }
                                Button("Delete Forever", role: .destructive) { run("Deleted.") { try await model.deleteForever([file.id]) } }
                            }
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
        .tvPageBackground()
        .task {
            guard model == nil, let putio = app.putio else { return }
            let trash = TrashModel(putio: putio)
            trash.onChange = { [app] in app.putioFilesChanged() }
            model = trash
            await trash.load()
        }
        .confirmationDialog("Empty the trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { run("Trash emptied.") { try await model?.empty() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in it is deleted for good (\(Format.bytes(model?.size ?? 0))). This can't be undone.")
        }
    }

    private var subtitle: String {
        guard let model, model.loaded else { return "Deleted files wait here before put.io removes them." }
        if model.files.isEmpty { return "Empty" }
        return "\(model.files.count) item\(model.files.count == 1 ? "" : "s") · \(Format.bytes(model.size)) · Hold Select to restore"
    }

    private func run(_ success: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
                notice = success
            } catch {
                notice = "put.io didn't accept that. Check your connection and try again."
                await model?.load()
            }
        }
    }
}
