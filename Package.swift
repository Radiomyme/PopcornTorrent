// swift-tools-version:5.4.0
import PackageDescription

let package = Package(
    name: "PopcornTorrent",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v12), .tvOS(.v12), .macOS(.v11)
    ],
    products: [
        .library(name: "PopcornTorrent", targets: ["PopcornTorrent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/alextud/GCDWebServer", .branch("swift-package-manager")),
    ],
    targets: [
        .target(
            name: "PopcornTorrent",
            dependencies: ["GCDWebServer"],
            path: "PopcornTorrent/Sources",
            exclude: [],
            cxxSettings: [
                .define("TARGET_OS_IOS", .when(platforms: [.iOS])),
                .define("TARGET_OS_TV", .when(platforms: [.tvOS])),
                .define("TARGET_OS_MAC", .when(platforms: [.macOS])),
                .define("BOOST_ASIO_HASH_MAP_BUCKETS", to: "1021"),
                .define("TORRENT_ABI_VERSION", to: "3"),
                .headerSearchPath("../../include/"),
            ],
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        ),
        // Pure logic of bounded storage (offline, no network, well under a second):
        // swift test --filter PopcornTorrentLogicTests
        .testTarget(name: "PopcornTorrentLogicTests",
                    dependencies: ["PopcornTorrent"],
                    path: "PopcornTorrentLogicTests",
                    linkerSettings: [
                        .linkedFramework("MediaPlayer")
                    ]),
        // The streamer end to end, offline (a few seconds): a generated season pack, a
        // seeder on 127.0.0.1, the session loopback-only (no tracker, DHT, LSD, UPnP, NAT-PMP).
        .testTarget(name: "PopcornTorrent-Tests",
                    dependencies: [.targetItem(name: "PopcornTorrent", condition: nil)],
                    path: "PopcornTorrentTests",
                    cxxSettings: [
                        .define("TORRENT_ABI_VERSION", to: "3"),
                        .define("BOOST_ASIO_HASH_MAP_BUCKETS", to: "1021"),
                        .headerSearchPath("../include"),
                        .headerSearchPath("../PopcornTorrent/Sources/Client"),
                    ],
                    linkerSettings: [
                        .linkedFramework("MediaPlayer"),
                        .linkedFramework("SystemConfiguration")
                    ]),
        // Streams PUBLIC torrents from the internet (minutes, real swarms): skipped unless
        // the test environment sets PT_INTERNET_TESTS=1.
        .testTarget(name: "PopcornTorrentInternetTests",
                    dependencies: [.targetItem(name: "PopcornTorrent", condition: nil)],
                    path: "PopcornTorrentInternetTests",
                    resources: [.copy("big-buck-bunny.torrent")],
                    linkerSettings: [
                        .linkedFramework("MediaPlayer")
                    ]
                   )
    ],
    cLanguageStandard: .gnu99,
    cxxLanguageStandard: .gnucxx17
)
