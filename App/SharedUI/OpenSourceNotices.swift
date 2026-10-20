import Foundation

/// The open-source code inside the built-in player, with the notices and license texts their licenses ask the app to
/// carry (Settings → About → Open Source). AetherEngine is LGPL-3.0 with an App Store exception; FFmpeg is LGPL-2.1
/// and ships as separate (dynamically linked) frameworks, so it can be replaced with a modified build.
enum OpenSourceNotices {
    struct Notice: Identifiable {
        let name: String
        let detail: String
        let license: String
        let source: String
        /// Bundled license texts (Licenses/*.txt), in order.
        let texts: [String]
        var id: String { name }
    }

    static let all: [Notice] = [
        Notice(name: "AetherEngine 7.44.0",
               detail: "The built-in player for videos Apple's player can't play. Copyright © 2026 Vincent Herbst. Used unmodified.",
               license: "GNU LGPL 3.0 with the App Store / DRM exception",
               source: "https://github.com/superuser404notfound/AetherEngine/tree/7.44.0",
               texts: ["AetherEngine-LGPL-3.0", "GPL-3.0"]),
        Notice(name: "FFmpeg",
               detail: "This app uses code of FFmpeg (libavcodec, libavformat, libavutil, libswresample, libswscale, "
                   + "libavfilter) licensed under the LGPLv2.1, built without GPL parts by FFmpegBuild. It's in the app as "
                   + "separate frameworks. FFmpeg is a trademark of Fabrice Bellard.",
               license: "GNU LGPL 2.1 or later",
               source: "https://github.com/superuser404notfound/FFmpegBuild (build script and patches) · https://ffmpeg.org",
               texts: ["FFmpeg-LGPL-2.1"]),
        Notice(name: "dav1d", detail: "AV1 decoding. Copyright © 2018-2019, VideoLAN and dav1d authors.",
               license: "BSD 2-Clause", source: "https://code.videolan.org/videolan/dav1d", texts: ["dav1d-BSD-2-Clause"]),
        Notice(name: "libzvbi", detail: "Teletext subtitles. Its GPL parts are left out of the build.",
               license: "GNU LGPL 2.0 or later (as 2.1); ure.c MIT", source: "https://github.com/zapping-vbi/zvbi",
               texts: ["FFmpeg-LGPL-2.1", "libzvbi-ure-MIT"]),
        Notice(name: "libdovi (dovi_tool)", detail: "Dolby Vision metadata. Copyright © quietvoid and contributors.",
               license: "MIT", source: "https://github.com/quietvoid/dovi_tool", texts: ["libdovi-MIT"]),
        Notice(name: "zimg", detail: "Picture scaling and color conversion.", license: "WTFPL (no conditions)",
               source: "https://github.com/sekrit-twc/zimg", texts: []),
    ]

    /// A bundled license text.
    static func text(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
