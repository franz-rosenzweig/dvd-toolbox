// swift-tools-version:6.2
// DVD Toolbox: a native Mac app that rips a DVD in the drive, names it the way Jellyfin expects from
// TMDB, and sends it to the library on the server. build.sh wraps it into an .app.
import PackageDescription

let package = Package(
    name: "DVDToolbox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "DVDToolbox", path: "Sources/DVDToolbox")
    ],
    swiftLanguageModes: [.v5]
)
