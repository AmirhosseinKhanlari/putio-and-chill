import AMDBKit
import SwiftUI

struct CountdownOverlay: View {
    let transfer: TrackedTransfer
    @Environment(Router.self) private var router
    @Environment(\.keyNavTab) private var tab
    @State private var remaining = 5

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    ProgressRing(progress: Double(5 - remaining) / 5, lineWidth: 5)
                    Text("\(remaining)").font(.system(size: 34, weight: .ultraLight)).monospacedDigit()
                }
                .frame(width: 88, height: 88)
                Text("\(transfer.pending.title) is ready").font(.title3.weight(.semibold))
                Text("Starting…").foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 12) {
                    Button { start() } label: { Label("Play Now", systemImage: "play.fill") }.buttonStyle(.primaryPill)
                    Button("Cancel") { router.countdown = nil }.buttonStyle(.glassPill)
                }
            }
            .padding(32)
            .glassRounded(28)
        }
        .transition(.opacity)
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, router.countdown?.id == transfer.id else { return }
                // Hidden tabs stay mounted: the count waits while another tab is showing, so playback never starts
                // from a page (and a Cancel button) nobody can see.
                if let tab, router.tab != tab { continue }
                remaining -= 1
            }
            start()
        }
    }

    private func start() {
        guard router.countdown?.id == transfer.id else { return }
        router.countdown = nil
        router.play(transfer)
    }
}
