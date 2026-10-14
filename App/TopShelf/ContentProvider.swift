import TVServices

/// Apple TV Top Shelf: Continue Watching and Recently Added from the TV app's saved feed.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let feed = TopShelfFeed.load(), feed.sections.contains(where: { !$0.items.isEmpty }) else {
            completionHandler(nil)
            return
        }
        let sections = feed.sections.filter { !$0.items.isEmpty }.map { section in
            let collection = TVTopShelfItemCollection(items: section.items.map(Self.item))
            collection.title = section.title
            return collection
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ item: TopShelfFeed.Item) -> TVTopShelfSectionedItem {
        let shelfItem = TVTopShelfSectionedItem(identifier: item.id)
        shelfItem.title = item.title
        shelfItem.imageShape = .hdtv
        if let url = item.imageURL {
            shelfItem.setImageURL(url, for: .screenScale1x)
            shelfItem.setImageURL(url, for: .screenScale2x)
        }
        shelfItem.displayAction = TVTopShelfAction(url: item.displayLink)
        if let play = item.playLink { shelfItem.playAction = TVTopShelfAction(url: play) }
        return shelfItem
    }
}
