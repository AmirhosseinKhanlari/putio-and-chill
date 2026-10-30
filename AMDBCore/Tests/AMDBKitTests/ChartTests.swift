import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct ChartTests {
    func makeModel(bundledTrakt: String?, charts: FakeCharts) -> AppModel {
        let factory = ServiceFactory(
            makePutio: { _ in FakePutio() },
            makeCatalog: { _ in FakeCatalog() },
            makeProvider: { config in FakeProvider(id: config.id) },
            makeCharts: { _ in charts })
        return AppModel(tokens: InMemoryTokenStore([.putio: "p", .tmdb: "t"]), defaults: testDefaults(),
                        store: LocalStore(fileURL: nil), factory: factory, bundledTraktClientID: bundledTrakt)
    }

    @Test func chartsNeedClientIDAndAreCached() async throws {
        let charts = FakeCharts()
        #expect(!makeModel(bundledTrakt: nil, charts: charts).hasCharts)
        #expect(!makeModel(bundledTrakt: "  ", charts: charts).hasCharts)
        let model = makeModel(bundledTrakt: "CID", charts: charts)
        #expect(model.hasCharts)
        #expect(try await model.chart(.top250Movies).count == 2)
        #expect(try await model.chart(.top250Movies).count == 2)
        #expect(charts.calls == 1)
    }

    @Test func chartModelLoadsAndResolvesPosters() async throws {
        let charts = FakeCharts()
        let app = makeModel(bundledTrakt: "CID", charts: charts)
        let chart = ChartModel(chart: .top250Movies, app: app, catalog: FakeCatalog())
        await chart.load()
        #expect(chart.entries.map(\.rank) == [1, 2])
        #expect(chart.error == nil)
        let first = await chart.item(for: chart.entries[0])
        #expect(first?.tmdbID == 278)
        #expect(chart.items[chart.entries[0].id]?.posterPath == "/p278.jpg")
        #expect(await chart.item(for: chart.entries[1]) == nil)
    }

    @Test func trailerComesFromFactory() async {
        struct FakeTrailers: TrailerService {
            func trailer(imdbID: String) async throws -> TrailerVideo? {
                imdbID == "tt1" ? TrailerVideo(name: "Trailer", url: URL(string: "https://v.test/t.m3u8")!) : nil
            }
        }
        let factory = ServiceFactory(makePutio: { _ in FakePutio() }, makeCatalog: { _ in FakeCatalog() },
                                     makeProvider: { _ in nil }, trailers: FakeTrailers())
        let app = AppModel(tokens: InMemoryTokenStore(), defaults: testDefaults(), store: LocalStore(fileURL: nil), factory: factory)
        #expect(await app.trailer(imdbID: "tt1")?.url.absoluteString == "https://v.test/t.m3u8")
        #expect(await app.trailer(imdbID: "tt2") == nil)
    }
}
