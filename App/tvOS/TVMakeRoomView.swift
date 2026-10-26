import AMDBCore
import AMDBKit
import SwiftUI

/// "Not enough space on put.io" on the TV: what could be deleted to make room, the suggestion ticked; select a row to
/// tick or untick it. Nothing is deleted until Delete & Get; a second question follows when put.io still counts the
/// deleted items in its Trash.
struct TVMakeRoomView: View {
    let offer: RoomOffer
    /// Called when it closes, with what to tell the user once the download was sent.
    var onFinish: (String?) -> Void = { _ in }
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session: RoomSession?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                TVPageHeader(title: offer.headline, subtitle: offer.message).padding(.bottom, 10)
                if let session { content(session) } else { ProgressView() }
            }
            .padding(TVMetrics.edge)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .tvPageBackground()
        .task { if session == nil { session = app.transfers.room.session(for: offer) } }
        .onExitCommand { if !isWorking { close(nil) } }
    }

    private var isWorking: Bool {
        if case .working = session?.phase { return true }
        return false
    }

    private func close(_ message: String?) {
        if session?.deleted.isEmpty == false { Task { await app.library.refresh(afterChanges: true) } }
        onFinish(message)
        dismiss()
    }

    @ViewBuilder private func content(_ session: RoomSession) -> some View {
        switch session.phase {
        case .choosing: choosing(session)
        case let .working(text):
            HStack(spacing: 20) { ProgressView(); Text(text).font(.system(size: 26)) }.padding(.top, 30)
        case let .trash(items):
            Text("These are in put.io's Trash and still use space. Delete them permanently?")
                .font(.system(size: 28, weight: .semibold))
            ForEach(items) { item in
                Text("\(item.name) · \(RoomFormat.bytes(item.size ?? 0))").font(.system(size: 24)).foregroundStyle(TVMetrics.secondaryText)
            }
            HStack(spacing: 30) {
                Button(role: .destructive) { Task { await session.purgeTrash() } } label: { Text("Delete Permanently") }.tvPill()
                Button { session.keepInTrash() } label: { Text("Keep in Trash") }.tvPill()
            }
            .padding(.top, 20)
        case let .done(message): ProgressView().task { close(message) }
        case let .failed(message):
            Text(message).font(.system(size: 26, weight: .semibold))
            Button("OK") { close(nil) }.tvPill().padding(.top, 20)
        }
    }

    @ViewBuilder private func choosing(_ session: RoomSession) -> some View {
        if let explanation = offer.explanation {
            Text(explanation).font(.system(size: 26, weight: .semibold))
            Button("OK") { close(nil) }.tvPill().padding(.top, 20)
        } else {
            Text("Delete these to make room? Watched titles go first, then the oldest.")
                .font(.system(size: 24)).foregroundStyle(TVMetrics.secondaryText)
            HStack(spacing: 30) {
                Button(role: .destructive) { Task { await session.confirm() } } label: {
                    Text(deleteLabel)
                }
                .tvPill()
                .disabled(!session.canDelete)
                Button("Cancel") { close(nil) }.tvPill()
                Text("Frees \(RoomFormat.bytes(session.freed)) · needs \(RoomFormat.bytes(offer.needed))")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(session.isEnough ? .green : .red)
            }
            .padding(.vertical, 10)
            ForEach(session.candidates) { candidate in
                Button { session.toggle(candidate.id) } label: {
                    row(candidate, selected: session.selection.contains(candidate.id))
                }
                .tvRow()
            }
        }
    }

    private var deleteLabel: String {
        if case .retry = offer.action { return "Delete & Retry" }
        return "Delete & Get"
    }

    private func row(_ candidate: RoomCandidate, selected: Bool) -> some View {
        HStack(spacing: 24) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 32))
            RemoteImage(path: candidate.posterPath, size: "w185", seed: candidate.title)
                .frame(width: 60, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text([candidate.title, candidate.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 26, weight: .semibold)).lineLimit(1)
                Text(status(candidate)).font(.system(size: 20)).opacity(0.7)
            }
            Spacer()
            Text(RoomFormat.bytes(candidate.size)).font(.system(size: 24, weight: .semibold))
        }
    }

    private func status(_ candidate: RoomCandidate) -> String {
        let watched = candidate.watched ? "Watched" : "Not watched yet"
        guard let added = candidate.addedAt else { return watched }
        return "\(watched) · Added \(added.formatted(date: .abbreviated, time: .omitted))"
    }
}

extension View {
    /// Shows the make-room page the app asked for (Get & Watch, a retry), and its result in the corner.
    func tvMakeRoomCover(_ app: AppModel, router: TVRouter) -> some View {
        fullScreenCover(item: Binding(get: { app.transfers.room.offer }, set: { app.transfers.room.offer = $0 })) { offer in
            TVMakeRoomView(offer: offer) { message in
                if let message { router.notice = message }
            }
            .environment(app)
            .environment(router)
        }
    }
}

/// For a download put.io stopped for lack of space: offers to make room, then retries it.
struct TVMakeRoomRetryButton: View {
    let transfer: TrackedTransfer
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var working = false

    var body: some View {
        Button {
            Task {
                working = true
                defer { working = false }
                switch await app.transfers.room.prepareRetry(transfer) {
                case let .offer(offer): app.transfers.room.offer = offer
                case .retried: router.notice = "Trying \(transfer.pending.title) again"
                case let .failed(message): router.notice = message
                }
            }
        } label: { Label("Make Room & Retry", systemImage: "externaldrive.badge.minus") }
        .tvPill()
        .disabled(working)
    }
}
