// swift-tools-version:5.5
//
// Offline end-to-end harness for bounded storage: generates a file, seeds it
// from a loopback-only libtorrent session and streams it with PTTorrentStreamer
// into a small APFS disk image. See run_harness.sh and BOUNDED_STORAGE.md.
//
import Foundation
import PackageDescription

let forkRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "BoundedStorageHarness",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(name: "PopcornTorrent", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "BoundedStorageHarness",
            dependencies: [.product(name: "PopcornTorrent", package: "PopcornTorrent")],
            cxxSettings: [
                // The seeder uses libtorrent directly, with the fork's ABI settings.
                .define("TORRENT_ABI_VERSION", to: "3"),
                .define("BOOST_ASIO_HASH_MAP_BUCKETS", to: "1021"),
                .unsafeFlags(["-I", forkRoot + "/include", "-I", forkRoot + "/PopcornTorrent/Sources/Client"]),
            ],
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ],
    cxxLanguageStandard: .gnucxx17
)
