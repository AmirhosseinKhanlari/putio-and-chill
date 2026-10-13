import AMDBCore
import SwiftUI

struct TitleView: View {
    let item: CatalogItem
    var body: some View { Text(item.title).font(.largeTitle).ambientBackground() }
}
