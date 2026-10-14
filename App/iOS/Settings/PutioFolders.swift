import AMDBCore
import AMDBKit
import SwiftUI

/// Browse put.io folders and pick one (or create one). `selection` nil means the default Putio & Chill folder.
struct PutioFolderPicker: View {
    let title: String
    let defaultPath: String
    @Binding var selection: PutioFolderRef?

    var body: some View {
        FolderLevel(folderID: 0, path: [], title: title, defaultPath: defaultPath, selection: $selection)
    }
}

private struct FolderLevel: View {
    let folderID: Int64
    let path: [String]
    let title: String
    let defaultPath: String
    @Binding var selection: PutioFolderRef?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [PutioFile]?
    @State private var failed = false
    @State private var newFolderName = ""
    @State private var askingName = false

    var body: some View {
        List {
            if path.isEmpty {
                Section {
                    Button { selection = nil; dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Default").foregroundStyle(.primary)
                                Text(defaultPath).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection == nil { Image(systemName: "checkmark").foregroundStyle(Theme.good) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Putio & Chill creates and uses this folder. Or pick any folder in your put.io below.")
                }
            }
            Section(path.isEmpty ? "Your put.io" : path.joined(separator: "/")) {
                if let folders {
                    if folders.isEmpty { Text("No folders here").foregroundStyle(.secondary) }
                    ForEach(folders) { folder in
                        NavigationLink {
                            FolderLevel(folderID: folder.id, path: path + [folder.name], title: folder.name, defaultPath: defaultPath,
                                        selection: $selection)
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                if selection?.id == folder.id { Image(systemName: "checkmark").foregroundStyle(Theme.good) }
                            }
                        }
                    }
                } else if failed {
                    Text("Couldn't load folders from put.io.").foregroundStyle(Theme.poor)
                } else {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(path.last ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { askingName = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Spacer()
                if !path.isEmpty {
                    Button("Use \u{201C}\(path.last ?? "")\u{201D}") {
                        selection = PutioFolderRef(id: folderID, path: path.joined(separator: "/"))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .alert("New folder", isPresented: $askingName) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Created in \(path.isEmpty ? "your put.io" : path.joined(separator: "/")).")
        }
        .task { await load() }
    }

    private func load() async {
        guard let putio = app.putio else { failed = true; return }
        do {
            folders = try await putio.listFiles(parentID: folderID).files.filter(\.isFolder)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            failed = true
        }
    }

    private func create() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        newFolderName = ""
        guard !name.isEmpty, let putio = app.putio, let folder = try? await putio.createFolder(name: name, parentID: folderID) else { return }
        folders = ((folders ?? []) + [folder]).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// "Organize library": preview what moves where, then move it.
struct OrganizeSheet: View {
    let layout: FolderLayout
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var plan: OrganizePlan?
    @State private var error: String?
    @State private var moving = false
    @State private var moved: Int?

    var body: some View {
        NavigationStack {
            List {
                if let moved {
                    Section {
                        Label("Moved \(moved) item\(moved == 1 ? "" : "s"). Your library is up to date.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good)
                    }
                } else if let plan {
                    Section {
                        Text(summary(plan)).font(.subheadline)
                    }
                    let groups = Dictionary(grouping: plan.moves, by: \.destination)
                    ForEach(groups.keys.sorted(), id: \.self) { destination in
                        Section {
                            ForEach(groups[destination] ?? []) { move in
                                Label(move.name, systemImage: move.isFolder ? "folder" : "film")
                                    .font(.footnote).lineLimit(2)
                            }
                        } header: {
                            Label(destination, systemImage: "arrow.turn.down.right")
                        }
                    }
                    if !plan.unrecognized.isEmpty {
                        Section {
                            ForEach(plan.unrecognized) { entry in
                                Text(entry.file.name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } header: {
                            Text("Left where they are")
                        } footer: {
                            Text("Putio & Chill isn't sure what these are, so it doesn't move them.")
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(Theme.poor)
                } else {
                    HStack { ProgressView(); Text("Looking through your library…").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Organize Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(moved == nil ? "Cancel" : "Done") { dismiss() } }
                if let plan, !plan.isEmpty, moved == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await apply(plan) } } label: {
                            if moving { ProgressView() } else { Text("Move \(plan.moves.count)").fontWeight(.semibold) }
                        }
                        .disabled(moving)
                    }
                }
            }
            .task {
                do { plan = try await app.planOrganize(layout: layout) } catch { self.error = "Couldn't read your put.io folders. Try again." }
            }
        }
    }

    private func summary(_ plan: OrganizePlan) -> String {
        var parts: [String] = []
        parts.append(plan.isEmpty ? "Everything is already in the right folder." : "\(plan.moves.count) item\(plan.moves.count == 1 ? "" : "s") will move.")
        if plan.inPlace > 0 { parts.append("\(plan.inPlace) already in place.") }
        if !plan.unrecognized.isEmpty { parts.append("\(plan.unrecognized.count) not recognized, left alone.") }
        return parts.joined(separator: " ")
    }

    private func apply(_ plan: OrganizePlan) async {
        moving = true
        defer { moving = false }
        do {
            moved = try await app.applyOrganize(plan, layout: layout)
        } catch {
            self.error = "Some items couldn't be moved. Nothing was deleted; try again."
            self.plan = nil
        }
    }
}
