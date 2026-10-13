import Testing
@testable import AMDBCore

struct ParserCase: Sendable, CustomTestStringConvertible {
    let name: String
    var title: String
    var year: Int? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var episodeEnd: Int? = nil
    var resolution: Resolution = .unknown
    var source: String? = nil
    var codec: String? = nil
    var hdr: [String] = []
    var audio: String? = nil
    var group: String? = nil
    var proper = false, repack = false, extended = false, complete = false
    var testDescription: String { name }
}

let parserCases: [ParserCase] = [
    ParserCase(name: "Furiosa.A.Mad.Max.Saga.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX",
               title: "Furiosa A Mad Max Saga", year: 2024, resolution: .uhd2160, source: "WEB-DL",
               codec: "H.265", hdr: ["HDR", "DV"], audio: "Atmos", group: "FLUX"),
    ParserCase(name: "Furiosa (2024) [1080p] [WEBRip] [5.1] [YTS.MX]",
               title: "Furiosa", year: 2024, resolution: .fhd1080, source: "WEBRip"),
    ParserCase(name: "Severance.S02E04.Woes.Hollow.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb",
               title: "Severance", season: 2, episode: 4, resolution: .fhd1080, source: "WEB-DL",
               codec: "H.264", audio: "DD+", group: "NTb"),
    ParserCase(name: "Shogun.2024.S01.COMPLETE.2160p.DSNP.WEB-DL.DDP5.1.HDR.H.265-NTb",
               title: "Shogun", year: 2024, season: 1, resolution: .uhd2160, source: "WEB-DL",
               codec: "H.265", hdr: ["HDR"], audio: "DD+", group: "NTb", complete: true),
    ParserCase(name: "The.Office.US.S05E14-E15.720p.HDTV.x264-LOL",
               title: "The Office US", season: 5, episode: 14, episodeEnd: 15, resolution: .hd720,
               source: "HDTV", codec: "H.264", group: "LOL"),
    ParserCase(name: "2001.A.Space.Odyssey.1968.REMASTERED.1080p.BluRay.x264-AMIABLE",
               title: "2001 A Space Odyssey", year: 1968, resolution: .fhd1080, source: "BluRay",
               codec: "H.264", group: "AMIABLE"),
    ParserCase(name: "Blade Runner 2049 (2017) 1080p BluRay x265 10bit AAC 7.1",
               title: "Blade Runner 2049", year: 2017, resolution: .fhd1080, source: "BluRay",
               codec: "H.265", audio: "AAC"),
    ParserCase(name: "1917.2019.1080p.BluRay.x264-SPARKS",
               title: "1917", year: 2019, resolution: .fhd1080, source: "BluRay", codec: "H.264", group: "SPARKS"),
    ParserCase(name: "Oppenheimer.2023.IMAX.2160p.UHD.BluRay.REMUX.HDR10Plus.DV.TrueHD.Atmos.7.1-FGT",
               title: "Oppenheimer", year: 2023, resolution: .uhd2160, source: "REMUX",
               hdr: ["HDR10+", "DV"], audio: "Atmos", group: "FGT"),
    ParserCase(name: "Breaking Bad 3x07 One Minute 720p",
               title: "Breaking Bad", season: 3, episode: 7, resolution: .hd720),
    ParserCase(name: "Dune.Part.Two.2024.PROPER.1080p.WEB.h264-ETHEL",
               title: "Dune Part Two", year: 2024, resolution: .fhd1080, source: "WEB", codec: "H.264",
               group: "ETHEL", proper: true),
    ParserCase(name: "Movie.Name.2022.720p.WEB-DL",
               title: "Movie Name", year: 2022, resolution: .hd720, source: "WEB-DL"),
    ParserCase(name: "Some.Show.S03E01.REPACK.1080p.WEB.H264-GGEZ[eztv.re].mkv",
               title: "Some Show", season: 3, episode: 1, resolution: .fhd1080, source: "WEB",
               codec: "H.264", group: "GGEZ", repack: true),
    ParserCase(name: "Aliens.1986.Special.Edition.EXTENDED.480p",
               title: "Aliens", year: 1986, resolution: .sd480, extended: true),
    ParserCase(name: "Some Random Name", title: "Some Random Name"),
    ParserCase(name: "[YTS.MX] Past Lives (2023) [720p]",
               title: "Past Lives", year: 2023, resolution: .hd720),
]

@Suite struct ReleaseNameParserTests {
    @Test(arguments: parserCases)
    func parses(_ c: ParserCase) {
        let p = ReleaseNameParser.parse(c.name)
        #expect(p.title == c.title)
        #expect(p.year == c.year)
        #expect(p.season == c.season)
        #expect(p.episode == c.episode)
        #expect(p.episodeEnd == c.episodeEnd)
        #expect(p.resolution == c.resolution)
        #expect(p.source == c.source)
        #expect(p.codec == c.codec)
        #expect(p.hdr == c.hdr)
        #expect(p.audio == c.audio)
        #expect(p.group == c.group)
        #expect(p.isProper == c.proper)
        #expect(p.isRepack == c.repack)
        #expect(p.isExtended == c.extended)
        #expect(p.isComplete == c.complete)
    }

    @Test func seasonPackFlag() {
        #expect(ReleaseNameParser.parse("Shogun.S01.1080p").isSeasonPack)
        #expect(!ReleaseNameParser.parse("Shogun.S01E01.1080p").isSeasonPack)
    }
}
