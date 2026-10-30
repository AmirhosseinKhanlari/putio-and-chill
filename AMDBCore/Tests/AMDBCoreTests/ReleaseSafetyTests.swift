import Foundation
import Testing
@testable import AMDBCore

private let MB: Int64 = 1_048_576
private let GB: Int64 = 1_073_741_824

private func check(_ name: String, _ size: Int64?, _ query: MediaQuery? = nil) -> ReleaseRejection? {
    ReleaseSafety.rejection(name: name, sizeBytes: size, parsed: ReleaseNameParser.parse(name), query: query)
}

@Suite struct ReleaseSafetyTests {
    /// Real-style names at real-style sizes, from scene, P2P, YTS, EZTV and anime uploads.
    static let good: [(String, Int64?)] = [
        ("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX", 31 * GB),
        ("Dune.Part.Two.2024.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR", 64 * GB),
        ("Dune Part Two 2024 NORDiC 1080p REMUX BluRay AVC DTS-HD MA TrueHD 7 1 Atmos", 34 * GB),
        ("Dune.Part.Two.2024.1080p.WEBRip.1600MB.DD2.0.x264-GalaxyRG", 1600 * MB),
        ("Dune Part Two (2024) [1080p] [WEBRip] [YTS]", 2800 * MB),
        ("Dune Part Two (2024) [720p] [BluRay] [YTS]", 1500 * MB),
        ("Dune Part Two (2024) [2160p] [WEB] [YTS]", 5600 * MB),
        ("Dune.Part.Two.2024.1080p.BluRay.x264.AAC5.1-[YTS.MX].mp4", 3 * GB),
        ("The.Last.of.Us.S02E02.1080p.WEB.h264-ETHEL", 2900 * MB),
        ("The.Bear.S03E01.720p.HDTV.x264-SYNCOPY", 400 * MB),
        ("Bluey.S03E01.1080p.WEB.h264-NOMA", 120 * MB),
        ("Monster The Ed Gein Story S01 1080p HEVC x265-MeGusta", 5 * GB),
        ("Severance.S02.COMPLETE.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX", 80 * GB),
        ("Shogun.2024.S01E01E02.1080p.DSNP.WEB-DL.DDP5.1.H.264-NTb", 5 * GB),
        ("www.UIndex.org    -    Severance S02E04 1080p WEB H264-SuccessfulCrab", 1500 * MB),
        ("[SubsPlease] Sousou no Frieren - 01 (1080p) [ABCDEF12].mkv", 1400 * MB),
        ("Harry Potter Complete 8-Film Collection 2160p UHD BluRay REMUX HDR", 420 * GB),
        ("The.Bat.1959.1080p.BluRay.x264-OFT", 7 * GB),
        ("Oppenheimer.2023.DVDSCR.x264-GROUP", 1100 * MB),
        ("Old.Movie.1999.SCR.XviD-GROUP", 700 * MB),
        ("Dune.Part.Two.2024.COMPLETE.UHD.BLURAY-SURCODE.iso", 90 * GB),
        ("Doctor.Who.2005.S01E01.Rose.480p.DVDRip.XviD", 180 * MB),
        ("Some.Movie.2023.1080p.WEB-DL", nil),
    ]

    @Test(arguments: good) func realReleasesPass(_ name: String, _ size: Int64?) {
        #expect(check(name, size) == nil, "\(name) was rejected: \(String(describing: check(name, size)))")
    }

    @Test func titleWordsAreNotFakeWords() {
        #expect(check("Crack.Cocaine.Corruption.and.Conspiracy.2021.1080p.NF.WEB-DL.DDP5.1.x264-NTG", 4 * GB,
                      .movie(imdbID: nil, title: "Crack: Cocaine, Corruption & Conspiracy", year: 2021)) == nil)
        #expect(check("The.Setup.2011.720p.BluRay.x264", 4 * GB, .movie(imdbID: nil, title: "Setup", year: 2011)) == nil)
        #expect(check("Password.2019.1080p.WEB-DL", 2 * GB, .text("Password 2019")) == nil)
        // The same word in another title's release still counts.
        #expect(check("Dune Part Two 2024 1080p Crack", 2 * GB, .movie(imdbID: nil, title: "Dune: Part Two", year: 2024))
            == .spam("crack"))
    }

    @Test func programsAreRejected() {
        #expect(check("Dune.Part.Two.2024.1080p.WEB-DL.x264.exe", 2 * GB) == .program("exe"))
        #expect(check("setup.exe", 3 * MB) == .program("exe"))
        #expect(check("Dune.Part.Two.2024.1080p.mkv.lnk", 2 * MB) == .program("lnk"))
        #expect(check("Dune Part Two 2024 1080p.exe [TGx]", 2 * GB) == .program("exe"))
        #expect(check("Dune.Part.Two.2024.2160p.apk", 2 * GB) == .program("apk"))
        #expect(check("Movie.2025.1080p.WEB.scr", 2 * GB) == .program("scr"))
    }

    @Test func archivesAndDiscImagesAreRejected() {
        #expect(check("Movie 2025 1080p FULL HD [codec required].zip", 900 * MB) == .archive("zip"))
        #expect(check("Movie.2025.2160p.rar", 20 * GB) == .archive("rar"))
        #expect(check("Movie.2025.1080p.7z", nil) == .archive("7z"))
        #expect(check("Movie.2025.1080p.iso", 700 * MB) == .discImage)
        #expect(check("Movie.2025.1080p.WEB.iso", 8 * GB) == .discImage)
        #expect(check("Movie.2025.BluRay.iso", 2 * GB) == .discImage)
        #expect(check("Movie.2025.1080p.BluRay.iso", 40 * GB) == nil)
    }

    @Test func fakeWordingIsRejected() {
        #expect(check("Dune Part Two 2024 1080p WEB-DL [Codec Required]", 2 * GB) == .spam("codec required"))
        #expect(check("Dune Part Two 2024 1080p Keygen", 2 * GB) == .spam("keygen"))
        #expect(check("Dune Part Two 2024 Full Movie Free Download HD", 2 * GB) == .spam("full movie free"))
        #expect(check("Dune Part Two 2024 1080p http://best-movies.xyz", 2 * GB) == .spam("web address"))
        #expect(check("Dune Part Two 2024 1080p [Password in txt]", 2 * GB) == .spam("password"))
        #expect(check("Dune Part Two 2024 Watch Online 1080p", 2 * GB) == .spam("watch online"))
    }

    @Test func implausibleSizesAreRejected() {
        #expect(check("Dune Part Two 2024 1080p", 4 * MB) == .tooSmall(bytes: 4 * MB, minimum: 150 * MB))
        #expect(check("Dune.Part.Two.2024.720p.WEB", 60 * MB) == .tooSmall(bytes: 60 * MB, minimum: 80 * MB))
        #expect(check("Dune.Part.Two.2024.2160p.WEB", 700 * MB) == .tooSmall(bytes: 700 * MB, minimum: GB))
        #expect(check("Dune.Part.Two.2024.DVDRip", 30 * MB) == .tooSmall(bytes: 30 * MB, minimum: 40 * MB))
        #expect(check("The.Last.of.Us.S02E02.1080p.WEB", 12 * MB) == .tooSmall(bytes: 12 * MB, minimum: 40 * MB))
        #expect(check("Shogun.S01E01-E03.1080p.WEB", 100 * MB) == .tooSmall(bytes: 100 * MB, minimum: 120 * MB))
        #expect(check("Severance.S02.1080p.WEB", 60 * MB) == .tooSmall(bytes: 60 * MB, minimum: 80 * MB))
        #expect(check("Dune.Part.Two.2024.2160p.REMUX", 200 * GB) == .tooLarge(bytes: 200 * GB, maximum: 150 * GB))
        #expect(check("The.Last.of.Us.S02E02.2160p.WEB", 70 * GB) == .tooLarge(bytes: 70 * GB, maximum: 60 * GB))
        // Unknown and zero sizes say nothing.
        #expect(check("Dune Part Two 2024 1080p", nil) == nil)
        #expect(check("Dune Part Two 2024 1080p", 0) == nil)
    }

    // MARK: File lists

    @Test func fileListsWithAVideoPass() {
        #expect(ReleaseSafety.rejection(files: [
            TorrentFile(name: "Dune.Part.Two.2024.1080p.WEBRip.x264.AAC-[YTS.MX].mp4", sizeBytes: 2_968_283_738),
            TorrentFile(name: "YTSYifyUP... (TOR).txt", sizeBytes: 583), TorrentFile(name: "www.YTS.MX.jpg", sizeBytes: 53226),
        ]) == nil)
        #expect(ReleaseSafety.rejection(files: [
            TorrentFile(name: "Dune/BDMV/STREAM/00001.m2ts", sizeBytes: 30 * GB), TorrentFile(name: "Dune/BDMV/index.bdmv", sizeBytes: 300),
        ]) == nil)
        #expect(ReleaseSafety.rejection(files: [TorrentFile(name: "Dune.2024.UHD.BluRay.iso", sizeBytes: 60 * GB)]) == nil)
        #expect(ReleaseSafety.rejection(files: []) == nil)
    }

    @Test func fileListsWithAProgramOrNoVideoAreRejected() {
        #expect(ReleaseSafety.rejection(files: [
            TorrentFile(name: "Dune.Part.Two.2024.1080p.mp4", sizeBytes: 2 * GB), TorrentFile(name: "Codec/Install Codec.exe", sizeBytes: 3 * MB),
        ]) == .containsProgram("Install Codec.exe"))
        #expect(ReleaseSafety.rejection(files: [
            TorrentFile(name: "Dune.Part.Two.2024.1080p.zip", sizeBytes: 2 * GB), TorrentFile(name: "readme.txt", sizeBytes: 100),
        ]) == .notVideo(largest: "Dune.Part.Two.2024.1080p.zip"))
        #expect(ReleaseSafety.rejection(files: [
            TorrentFile(name: "movie.part1.rar", sizeBytes: 900 * MB), TorrentFile(name: "movie.part2.rar", sizeBytes: 800 * MB),
        ]) == .notVideo(largest: "movie.part1.rar"))
    }

    // MARK: Inspector

    static let fileList = #"[{"name":["Dune.mkv"],"size":[2968283738]},{"name":["info.txt"],"size":[583]}]"#
    static let fakeList = #"[{"name":["Dune.Part.Two.2024.1080p.mp4.lnk"],"size":[2000]},{"name":["Dune.wmv"],"size":[90000000]},{"name":["codec.exe"],"size":[3000000]}]"#

    func apibayRelease(_ hash: Character, id: String, seeders: Int = 10, name: String = "Dune.Part.Two.2024.1080p.WEB") -> Release {
        Release(name: name, link: "magnet:?xt=urn:btih:\(String(repeating: hash, count: 40))", seeders: seeders,
                sources: [SourceTag(.direct, "TPB")], fileListURL: URL(string: "https://apibay.org/f.php?id=\(id)"))
    }

    @Test func inspectorReadsApibayListsAndRemembersThem() async {
        let stub = StubTransport { request in
            let id = request.queryItems["id"]
            return (200, Data((id == "2" ? Self.fakeList : Self.fileList).utf8))
        }
        let inspector = FileListInspector(transport: stub)
        let good = apibayRelease("a", id: "1"), fake = apibayRelease("b", id: "2")
        #expect(await inspector.files(for: good)?.map(\.name) == ["Dune.mkv", "info.txt"])
        #expect(await inspector.rejection(for: good) == nil)
        #expect(await inspector.rejection(for: fake) == .containsProgram("Dune.Part.Two.2024.1080p.mp4.lnk"))
        #expect(stub.requests.count == 2)
        // A list that came with the release is used as is.
        var inline = good
        inline.files = [TorrentFile(name: "x.exe", sizeBytes: 1)]
        #expect(await inspector.rejection(for: inline) == .containsProgram("x.exe"))
        #expect(stub.requests.count == 2)
    }

    @Test func unreadableListsCountAsFineAndAreRetried() async {
        let notFound = #"[{"name":{"0":"Filelist not found"},"size":{"0":"0"}}]"#
        let stub = StubTransport { request in
            request.queryItems["id"] == "1" ? (200, Data(notFound.utf8)) : (503, Data())
        }
        let inspector = FileListInspector(transport: stub)
        #expect(await inspector.rejection(for: apibayRelease("a", id: "1")) == nil)
        #expect(await inspector.rejection(for: apibayRelease("b", id: "2")) == nil)
        #expect(await inspector.rejection(for: apibayRelease("b", id: "2")) == nil)
        #expect(stub.requests.count == 3)
        #expect(await inspector.rejection(for: Release(name: "x", link: "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))",
                                                       sources: [])) == nil)
    }

    @Test func candidatesAreTheTopSeededPerResolutionAndEveryInlineList() {
        var releases = (0..<15).map { apibayRelease(Character(String(format: "%x", $0)), id: "\($0)", seeders: 100 - $0) }
        releases.append(apibayRelease("x", id: "720", seeders: 1, name: "Dune.Part.Two.2024.720p.WEB"))
        var inline = Release(name: "Dune.Part.Two.2024.2160p.WEB", link: "magnet:?xt=urn:btih:\(String(repeating: "f", count: 39))e",
                             seeders: 0, sources: [])
        inline.files = [TorrentFile(name: "a.mkv", sizeBytes: 1)]
        releases.append(inline)
        releases.append(Release(name: "No.List.2024.1080p", link: "https://x/y.torrent", seeders: 999, sources: []))
        let picked = FileListInspector.candidates(releases, limit: 10)
        #expect(picked.count == 12)
        #expect(picked.first == inline)
        #expect(picked.contains { $0.name.contains("720p") })
        #expect(!picked.contains { $0.name.hasPrefix("No.List") })
    }

    // MARK: Aggregator

    @Test func aggregatorHidesFakesByNameAndRemembered() async {
        let tag = SourceTag(.direct, "TPB")
        let good = release("a", seeders: 50, size: 2 * GB, tag: tag, name: "Dune.Part.Two.2024.1080p.WEB-DL")
        let exe = release("b", seeders: 900, size: 2 * GB, tag: tag, name: "Dune.Part.Two.2024.1080p.WEB-DL.exe")
        let tiny = release("c", seeders: 400, size: 4 * MB, tag: tag, name: "Dune.Part.Two.2024.1080p")
        let known = release("d", seeders: 300, size: 2 * GB, tag: tag, name: "Dune.Part.Two.2024.720p.WEB")
        let aggregator = ReleaseAggregator(providers: [FakeProvider(id: "tpb", result: .success([good, exe, tiny, known]))],
                                           blocked: { [String(repeating: "d", count: 40)] })
        let snapshot = await aggregator.collect(for: .movie(imdbID: nil, title: "Dune: Part Two", year: 2024))
        #expect(snapshot.releases.map(\.name) == [good.name])
        #expect(snapshot.hiddenCount == 3)
    }

    @Test func aggregatorChecksTopFileListsBeforeFinishing() async {
        let stub = StubTransport { request in
            (200, Data((request.queryItems["id"] == "2" ? Self.fakeList : Self.fileList).utf8))
        }
        let rows = [apibayRelease("a", id: "1", seeders: 10), apibayRelease("b", id: "2", seeders: 900)]
        let aggregator = ReleaseAggregator(providers: [FakeProvider(id: "tpb", result: .success(rows))],
                                           inspector: FileListInspector(transport: stub))
        var snapshots: [ReleaseSnapshot] = []
        for await snapshot in aggregator.stream(for: .text("Dune Part Two 2024")) { snapshots.append(snapshot) }
        #expect(snapshots.contains { $0.isCheckingFiles && !$0.isComplete })
        #expect(snapshots.dropLast().filter { $0.isComplete }.isEmpty)
        #expect(snapshots.last?.isComplete == true)
        #expect(snapshots.last?.releases.map(\.infoHash) == [String(repeating: "a", count: 40)])
        #expect(snapshots.last?.hiddenCount == 1)
    }

    @Test func blockedMatchesHashOrLink() {
        let linked = Release(name: "X.2024.1080p", link: "https://tracker.example/t/Abc", sources: [])
        #expect(ReleaseAggregator.isBlocked(linked, ["https://tracker.example/t/abc"]))
        #expect(!ReleaseAggregator.isBlocked(linked, []))
        #expect(ReleaseAggregator.isBlocked(release("e", seeders: 1, tag: SourceTag(.direct, "TPB")), [String(repeating: "e", count: 40)]))
    }

    // MARK: Sources

    @Test func apibayGivesAFileListLinkAndSkipsPrograms() async throws {
        let json = #"""
        [{"id":"75005578","name":"Dune Part Two (2024) [1080p] [WEBRip]","info_hash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","leechers":"1","seeders":"9","num_files":"3","size":"2968337547","category":"207"},
         {"id":"75005579","name":"Dune Part Two 2024 1080p","info_hash":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","leechers":"1","seeders":"9","num_files":"1","size":"2968337547","category":"301"}]
        """#
        let releases = try await ApibayProvider(transport: StubTransport(json: json)).releases(for: .text("Dune Part Two 2024"))
        #expect(releases.count == 1)
        #expect(releases[0].fileListURL?.absoluteString == "https://apibay.org/f.php?id=75005578")
    }

    @Test func torrentGalaxyDetailFileTable() {
        let html = #"""
        <table><tbody><tr><th class="table_head">File</th><th class="table_head">Size</th></tr>
        <tr>
            <td class="table_col1">Dune.Part.Two.2024.1080p.BluRay.x264.AAC5.1-[YTS.MX].mp4</td>
            <td class="table_col2">3.1 GB</td>
        </tr>
        <tr><td class="table_col1">YTSProxies.com.txt</td><td class="table_col2">584 bytes</td></tr>
        <tr><td class="table_col1">www.YTS.MX.jpg</td><td class="table_col2">52.0 KB</td></tr>
        </tbody></table>
        <td class="table_col1" style="max-width:240px;">${tracker.tracker}</td>
        <td class="table_col2" align="center"><span>${tracker.seeders}</span></td>
        """#
        let files = TorrentGalaxyPage.files(inDetail: html)
        #expect(files.map(\.name) == ["Dune.Part.Two.2024.1080p.BluRay.x264.AAC5.1-[YTS.MX].mp4", "YTSProxies.com.txt", "www.YTS.MX.jpg"])
        #expect(files.map(\.sizeBytes) == [Int64(3.1 * 1_073_741_824), 584, 53_248])
        #expect(ReleaseSafety.rejection(files: files) == nil)
    }
}
