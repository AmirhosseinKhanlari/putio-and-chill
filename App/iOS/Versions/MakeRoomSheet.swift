import AMDBCore
import AMDBKit
import SwiftUI

/// "Not enough space on put.io": what could be deleted to make room, with the suggestion ticked. Nothing is deleted
/// until Delete & Get; when put.io still counts the deleted items in its Trash, a second question asks before
/// removing exactly those for good.
struct MakeRoomSheet: View {
    let offer: RoomOffer
    /// Called when it closes, with what to tell the user once the download was sent ("Freed 9.8 GB · Getting Dune").
    var onFinish: (String?) -> Void = { _ in }
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session: RoomSession?

    var body: some View {
        NavigationStack {
            Group {
                if let session { content(session) } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.sheet)
            .navigationTitle("Make Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close(nil) }.disabled(isWorking).accessibilityIdentifier("makeRoom.cancel")
                }
            }
        }
        .presentationBackground(Theme.sheet)
        .interactiveDismissDisabled(isWorking)
        .task { if session == nil { session = app.transfers.room.session(for: offer) } }
    }

    private var isWorking: Bool {
        if case .working = session?.phase { return true }
        return false
    }

    private func close(_ message: String?) {
        // Something went: the library reads put.io again (what went is already off the screen).
        if session?.deleted.isEmpty == false { Task { await app.library.refresh(afterChanges: true) } }
        onFinish(message)
        dismiss()
    }

    @ViewBuilder private func content(_ session: RoomSession) -> some View {
        switch session.phase {
        case .choosing: choosing(session)
        case let .working(text):
            VStack(spacing: 12) {
                ProgressView()
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 80)
        case let .trash(items): trash(session, items)
        case let .done(message): ProgressView().padding(.top, 80).task { close(message) }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 16) {
                Text(message).font(.body).accessibilityIdentifier("makeRoom.message")
                Button("OK") { close(nil) }.buttonStyle(.primaryPill)
            }
            .padding(20)
        }
    }

    private func choosing(_ session: RoomSession) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(offer.headline).font(.title3.weight(.bold))
                        Text(offer.message).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                            .accessibilityIdentifier("makeRoom.message")
                        if let explanation = offer.explanation {
                            Text(explanation).font(.subheadline).foregroundStyle(Theme.poor).padding(.top, 4)
                        } else {
                            Text("Delete these to make room? Watched titles go first, then the oldest.")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.8)).padding(.top, 4)
                        }
                    }
                    ForEach(session.candidates) { candidate in
                        Button { session.toggle(candidate.id) } label: {
                            RoomCandidateRow(candidate: candidate, selected: session.selection.contains(candidate.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("makeRoom.row.\(candidate.id)")
                        .accessibilityAddTraits(session.selection.contains(candidate.id) ? .isSelected : [])
                    }
                }
                .padding(20)
            }
            if offer.canMakeRoom { footer(session) } else {
                Button("OK") { close(nil) }.buttonStyle(.primaryPill).padding(20)
            }
        }
    }

    private func footer(_ session: RoomSession) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Frees \(RoomFormat.bytes(session.freed))").font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.isEnough ? Theme.good : Theme.poor)
                    .accessibilityIdentifier("makeRoom.freed")
                Spacer()
                Text("Needs \(RoomFormat.bytes(offer.needed))").font(.subheadline).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { Task { await session.confirm() } } label: {
                Text(deleteLabel).foregroundStyle(Theme.poor).frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryPill)
            .tint(Theme.poor)
            .disabled(!session.canDelete)
            .accessibilityIdentifier("makeRoom.delete")
            Text("Deleted files go to put.io's Trash first.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var deleteLabel: String {
        if case .retry = offer.action { return "Delete & Retry" }
        return "Delete & Get"
    }

    private func trash(_ session: RoomSession, _ items: [PutioTrashFile]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Still in put.io's Trash").font(.title3.weight(.bold))
                Text("These are in put.io's Trash and still use space. Delete them permanently?")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                ForEach(items) { item in
                    HStack {
                        Image(systemName: item.isFolder ? "folder" : "film").foregroundStyle(.secondary)
                        Text(item.name).font(.subheadline).lineLimit(2)
                        Spacer()
                        Text(RoomFormat.bytes(item.size ?? 0)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) { Task { await session.purgeTrash() } } label: {
                    Text("Delete Permanently").foregroundStyle(Theme.poor).frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryPill).tint(Theme.poor)
                .accessibilityIdentifier("makeRoom.purge")
                Button { session.keepInTrash() } label: { Text("Keep in Trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassPill)
            }
            .padding(20)
        }
    }
}

/// One title that could go: poster, what it is, its size, whether it was watched, and when put.io got it.
private struct RoomCandidateRow: View {
    let candidate: RoomCandidate
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(selected ? Theme.poor : .white.opacity(0.4))
            RemoteImage(path: candidate.posterPath, size: "w185", seed: candidate.title)
                .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let detail = candidate.detail { Text(detail).font(.caption).foregroundStyle(.white.opacity(0.75)) }
                Text(RoomCandidateRow.status(candidate)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(RoomFormat.bytes(candidate.size)).font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(10)
        .background(.white.opacity(selected ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    static func status(_ candidate: RoomCandidate) -> String {
        let watched = candidate.watched ? "Watched" : "Not watched yet"
        guard let added = candidate.addedAt else { return watched }
        return "\(watched) · Added \(added.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// For a download put.io stopped for lack of space: offers to make room, then retries it.
struct MakeRoomRetryButton: View {
    let transfer: TrackedTransfer
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var working = false

    var body: some View {
        Button {
            Task {
                working = true
                defer { working = false }
                switch await app.transfers.room.prepareRetry(transfer) {
                case let .offer(offer): app.transfers.room.offer = offer
                case .retried: router.toast = "Trying \(transfer.pending.title) again"
                case let .failed(message): router.toast = message
                }
            }
        } label: {
            Label("Make Room & Retry", systemImage: "externaldrive.badge.minus")
        }
        .buttonStyle(.primaryPill)
        .disabled(working)
    }
}

extension View {
    /// Shows the make-room confirmation the app asked for (Get & Watch, a retry), and its result as a toast.
    func makeRoomSheet(_ app: AppModel, router: Router) -> some View {
        sheet(item: Binding(get: { app.transfers.room.offer }, set: { app.transfers.room.offer = $0 })) { offer in
            MakeRoomSheet(offer: offer) { message in
                if let message { router.toast = message }
            }
            .environment(app)
        }
    }
}
