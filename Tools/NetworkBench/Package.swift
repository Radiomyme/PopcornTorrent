// swift-tools-version:5.5
//
// Offline download benchmark: a swarm of libtorrent seeders on 127.0.0.1, each behind a
// userspace TCP proxy that adds a round-trip time and caps the peer's rate, so the request
// pipeline has a bandwidth-delay product to fill. Measures a stream (full or bounded storage)
// and an offline download with the fork's PTTorrentStreamer / PTTorrentDownload
// (see run_bench.sh, BOUNDED_STORAGE.md "Network").
//
import Foundation
import PackageDescription

let forkRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path

let package = Package(
    name: "NetworkBench",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(name: "PopcornTorrent", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "NetworkBench",
            dependencies: [.product(name: "PopcornTorrent", package: "PopcornTorrent")],
            cxxSettings: [
                .define("TORRENT_ABI_VERSION", to: "3"),
                .define("BOOST_ASIO_HASH_MAP_BUCKETS", to: "1021"),
                .unsafeFlags(["-I", forkRoot + "/include", "-I", forkRoot + "/PopcornTorrent/Sources/Client", "-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("MediaPlayer"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ],
    cxxLanguageStandard: .gnucxx17
)
