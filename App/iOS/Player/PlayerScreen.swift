import SwiftUI

struct PlayerScreen: View {
    let request: PlayerRequest
    var body: some View { Text(request.title) }
}
