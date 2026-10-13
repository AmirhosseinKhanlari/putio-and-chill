import AMDBCore
import AMDBKit
import SwiftUI

/// ＋ / ✓ My List toggle. `iconOnly` for tight spots like the hero.
struct MyListButton: View {
    let item: CatalogItem
    var iconOnly = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let saved = app.myList.contains(item)
        Button {
            Task { await app.myList.toggle(item) }
        } label: {
            if iconOnly {
                Image(systemName: saved ? "checkmark" : "plus").font(.headline).frame(width: 22, height: 22)
            } else {
                Label("My List", systemImage: saved ? "checkmark" : "plus")
            }
        }
        .buttonStyle(.glassPill)
        .contentTransition(.symbolEffect(.replace))
        .sensoryFeedback(.success, trigger: saved)
        .accessibilityLabel(saved ? "Remove from My List" : "Add to My List")
    }
}
