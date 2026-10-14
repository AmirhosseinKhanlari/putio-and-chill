import Testing
@testable import AMDBKit

@Suite struct DownloadPathsTests {
    let home = "/var/mobile/Containers/Data/Application/AAAA"

    @Test func storesFromLibraryEvenWhenTheSystemAddsPrivate() {
        let location = "/private/var/mobile/Containers/Data/Application/AAAA/Library/com.apple.UserManagedAssets.X1/Dune_123.movpkg"
        #expect(DownloadPaths.stored(location: location, home: home) == "Library/com.apple.UserManagedAssets.X1/Dune_123.movpkg")
    }

    @Test func storesPlainHomeRelativePaths() {
        #expect(DownloadPaths.stored(location: home + "/Library/a/b.movpkg", home: home) == "Library/a/b.movpkg")
    }

    @Test func resolvesRelativePathsUnderTheCurrentHome() {
        #expect(DownloadPaths.resolve(stored: "Library/a/b.movpkg", home: home) == home + "/Library/a/b.movpkg")
    }

    /// Records saved by older builds hold an absolute path, often from a container that has since moved.
    @Test func resolvesOldAbsolutePathsIntoTheCurrentContainer() {
        let old = "/private/var/mobile/Containers/Data/Application/OLD/Library/com.apple.UserManagedAssets.X1/Dune_123.movpkg"
        #expect(DownloadPaths.resolve(stored: old, home: home) == home + "/Library/com.apple.UserManagedAssets.X1/Dune_123.movpkg")
    }

    @Test func leavesUnknownAbsolutePathsAlone() {
        #expect(DownloadPaths.resolve(stored: "/tmp/x.movpkg", home: home) == "/tmp/x.movpkg")
    }
}
