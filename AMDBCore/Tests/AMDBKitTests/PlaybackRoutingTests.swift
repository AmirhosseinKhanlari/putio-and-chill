import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct PlaybackRoutingTests {
    // MARK: Codec info → verdict

    @Test func oldVideoCodecsAreNotForApple() {
        for codec in ["mpeg4", "msmpeg4v3", "mpeg2video", "vc1", "wmv3", "vp8"] {
            #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: [codec], audioCodecs: ["aac"])) == .appleCannotPlay(codec))
        }
        #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: ["h264"], audioCodecs: ["aac"])) == .applePlays)
        #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: ["hevc"], audioCodecs: ["eac3", "dts"])) == .applePlays,
                "one audio track Apple plays is enough")
    }

    @Test func audioApplesPlayerCantDecode() {
        #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: ["h264"], audioCodecs: ["dts"])) == .appleCannotPlay("dts"))
        #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: ["hevc"], audioCodecs: ["truehd", "dts"])) == .appleCannotPlay("truehd"))
    }

    @Test func vp9AndAV1DependOnHardware() {
        let vp9 = PutioMediaInfo(videoCodecs: ["vp9"], audioCodecs: ["opus"])
        #expect(CodecVerdict.of(vp9) == .appleCannotPlay("vp9"))
        #expect(CodecVerdict.of(vp9, hardwareVP9: true) == .applePlays)
        let av1 = PutioMediaInfo(videoCodecs: ["av1"], audioCodecs: ["aac"])
        #expect(CodecVerdict.of(av1) == .appleCannotPlay("av1"))
        #expect(CodecVerdict.of(av1, hardwareAV1: true) == .applePlays)
    }

    @Test func unknownCodecsAndCoverArt() {
        #expect(CodecVerdict.of(PutioMediaInfo()) == .unknown)
        #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: ["somethingnew"], audioCodecs: ["aac"])) == .unknown)
        #expect(CodecVerdict.of(PutioMediaInfo(videoCodecs: ["mjpeg", "mpeg4"], audioCodecs: ["mp3"])) == .appleCannotPlay("mpeg4"),
                "a cover image isn't the video")
    }

    // MARK: Route

    @Test func applesPlayerIsTheDefault() {
        #expect(first(needsConvert: false, verdict: .applePlays) == .play(.apple))
        #expect(first(needsConvert: false, verdict: .unknown) == .play(.apple))
        // put.io's "needs converting" alone isn't enough: it also flags videos only web browsers can't play.
        #expect(first(needsConvert: true, verdict: .applePlays) == .play(.apple))
        #expect(first(needsConvert: true, verdict: .unknown) == .play(.apple))
        // Codecs alone aren't either: put.io streams some of those fine.
        #expect(first(needsConvert: false, verdict: .appleCannotPlay("mpeg4")) == .play(.apple))
    }

    @Test func needsConvertingAndUndecodableGoesStraightToBuiltIn() {
        #expect(first(needsConvert: true, verdict: .appleCannotPlay("mpeg4")) == .play(.builtIn))
        // Not in the Mac app (no built-in player there), nor with "Convert with put.io".
        #expect(first(needsConvert: true, verdict: .appleCannotPlay("mpeg4"), builtInAvailable: false) == .play(.apple))
        #expect(first(needsConvert: true, verdict: .appleCannotPlay("mpeg4"), preference: .convert) == .play(.apple))
    }

    @Test func rememberedEngineWins() {
        #expect(first(remembered: .builtIn, needsConvert: false, verdict: .applePlays) == .play(.builtIn))
        #expect(first(remembered: .apple, needsConvert: true, verdict: .appleCannotPlay("vc1")) == .play(.apple))
        #expect(first(remembered: .builtIn, needsConvert: false, verdict: .unknown, builtInAvailable: false) == .play(.apple))
    }

    @Test func appleFailingTriesBuiltInBeforeConverting() {
        #expect(after(.apple, tried: [.apple], needsConvert: true) == .play(.builtIn))
        #expect(after(.apple, tried: [.apple], needsConvert: false) == .play(.builtIn))
        // Built-in already failed too: put.io's conversion, the last resort, only when put.io says it's needed.
        #expect(after(.apple, tried: [.apple, .builtIn], needsConvert: true) == .convert)
        #expect(after(.apple, tried: [.apple, .builtIn], needsConvert: false) == .fail)
        // "Convert with put.io", or the Mac app: straight to converting, as before.
        #expect(after(.apple, tried: [.apple], needsConvert: true, preference: .convert) == .convert)
        #expect(after(.apple, tried: [.apple], needsConvert: true, builtInAvailable: false) == .convert)
    }

    @Test func builtInFailingTriesAppleUnlessItCantDecode() {
        #expect(after(.builtIn, tried: [.builtIn], needsConvert: false, verdict: .unknown) == .play(.apple))
        #expect(after(.builtIn, tried: [.builtIn], needsConvert: true, verdict: .appleCannotPlay("mpeg4")) == .convert)
        #expect(after(.builtIn, tried: [.builtIn], needsConvert: false, verdict: .appleCannotPlay("mpeg4")) == .fail)
        #expect(after(.builtIn, tried: [.builtIn, .apple], needsConvert: true, verdict: .unknown) == .convert)
    }

    // MARK: Plan (with a fake put.io)

    @Test func planUsesPutiosCodecInfo() async {
        let putio = FakePutio()
        putio.needsMp4 = [7]
        putio.codecs[7] = (["mpeg4"], ["mp3"])
        let plan = makePlan(putio: putio, fileID: 7)
        #expect(await plan.firstStep() == .play(.builtIn))
        #expect(plan.verdict == .appleCannotPlay("mpeg4"))
        #expect(putio.conversionsStarted.isEmpty, "no conversion before trying the built-in player")
    }

    @Test func planFallsBackOnFailureAndConvertsOnlyLast() async {
        let putio = FakePutio()
        putio.add(PutioFile(id: 8, name: "Home.Video.mov", fileType: "VIDEO", size: 300), to: 0)
        putio.needsMp4 = [8]   // put.io says it needs converting, but its codecs aren't known
        let plan = makePlan(putio: putio, fileID: 8)
        #expect(await plan.firstStep() == .play(.apple))
        #expect(await plan.step(afterFailureOf: .apple) == .play(.builtIn))
        #expect(await plan.step(afterFailureOf: .builtIn) == .convert)
        // After converting, Apple's player gets the stream; if even that fails, nothing is left (no second conversion).
        #expect(await plan.step(afterFailureOf: .apple) == .fail)
    }

    @Test func planRemembersWhatWorked() async {
        let putio = FakePutio()
        let memory = PlaybackEngineMemory(defaults: freshDefaults())
        let plan = makePlan(putio: putio, fileID: 9, memory: memory)
        #expect(await plan.firstStep() == .play(.apple))
        #expect(await plan.step(afterFailureOf: .apple) == .play(.builtIn))
        plan.succeeded(.builtIn)
        #expect(memory.engine(fileID: 9) == .builtIn)

        // Next time: straight to the built-in player, without asking put.io about codecs.
        let requestsBefore = putio.mediaInfoRequests.count
        let next = makePlan(putio: putio, fileID: 9, memory: memory)
        #expect(await next.firstStep() == .play(.builtIn))
        #expect(putio.mediaInfoRequests.count == requestsBefore)
        // It stops working: forgotten, and Apple's player gets another chance.
        #expect(await next.step(afterFailureOf: .builtIn) == .play(.apple))
        #expect(memory.engine(fileID: 9) == nil)
    }

    @Test func plainApplePlaysAreNotStored() async {
        let memory = PlaybackEngineMemory(defaults: freshDefaults())
        let plan = makePlan(putio: FakePutio(), fileID: 10, memory: memory)
        #expect(await plan.firstStep() == .play(.apple))
        plan.succeeded(.apple)
        #expect(memory.engine(fileID: 10) == nil)
    }

    @Test func memoryPersists() {
        let defaults = freshDefaults()
        PlaybackEngineMemory(defaults: defaults).remember(.builtIn, fileID: 42)
        #expect(PlaybackEngineMemory(defaults: defaults).engine(fileID: 42) == .builtIn)
    }

    @Test func slowPutioDoesNotHoldUpPlayback() async {
        let plan = PlaybackPlan(fileID: 1, options: .init(preference: .builtIn, builtInAvailable: true, infoTimeout: .milliseconds(50)),
                                memory: PlaybackEngineMemory(defaults: freshDefaults()),
                                mediaInfo: { _ in
                                    try? await Task.sleep(for: .seconds(5))
                                    return PutioMediaInfo(videoCodecs: ["mpeg4"], needConvert: true)
                                },
                                needsConversion: { _ in false })
        let started = ContinuousClock.now
        #expect(await plan.firstStep() == .play(.apple))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func settingDefaultsToBuiltInAndRoundTrips() throws {
        #expect(AppSettings.defaults.unsupportedVideoPlayer == .builtIn)
        var settings = AppSettings.defaults
        settings.unsupportedVideoPlayer = .convert
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.unsupportedVideoPlayer == .convert)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoPlayCountdown":true}"#.utf8))
        #expect(old.unsupportedVideoPlayer == .builtIn)
    }

    // MARK: Helpers

    private func first(remembered: PlaybackEngineKind? = nil, needsConvert: Bool, verdict: CodecVerdict,
                       preference: UnsupportedVideoPlayer = .builtIn, builtInAvailable: Bool = true) -> PlaybackStep {
        PlaybackRoute.first(remembered: remembered, needsConvert: needsConvert, verdict: verdict, preference: preference,
                            builtInAvailable: builtInAvailable)
    }

    private func after(_ failed: PlaybackEngineKind, tried: Set<PlaybackEngineKind>, needsConvert: Bool,
                       verdict: CodecVerdict = .unknown, preference: UnsupportedVideoPlayer = .builtIn,
                       builtInAvailable: Bool = true) -> PlaybackStep {
        PlaybackRoute.after(failed: failed, tried: tried, needsConvert: needsConvert, verdict: verdict, preference: preference,
                            builtInAvailable: builtInAvailable)
    }

    private func makePlan(putio: FakePutio, fileID: Int64, memory: PlaybackEngineMemory? = nil) -> PlaybackPlan {
        let conversions = VideoConversions(pollInterval: .milliseconds(1))
        conversions.configure(putio: putio)
        return PlaybackPlan(fileID: fileID, options: .init(preference: .builtIn, builtInAvailable: true),
                            memory: memory ?? PlaybackEngineMemory(defaults: freshDefaults()),
                            mediaInfo: { id in try? await putio.mediaInfo(fileID: id) },
                            needsConversion: { id in await conversions.needsConversion(fileID: id) })
    }

    private func freshDefaults() -> UserDefaults {
        let name = "routing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
