// swift-tools-version: 6.0
import PackageDescription

// Four targets, because every failure the audit found (front door docs/ios-rewrite-plan.md § 1)
// was in glue that no test could reach. The rule is that anything with a decision in it builds
// and tests on macOS with `swift test`; anything that needs a radio, a receiver, the Keychain or
// the network is a thin adapter behind a protocol.
let package = Package(
    name: "CairnCompanion",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CairnProtocol", targets: ["CairnProtocol"]),
        .library(name: "CairnKit", targets: ["CairnKit"]),
        .library(name: "CairnRuntime", targets: ["CairnRuntime"]),
    ],
    dependencies: [
        // The only dependency the app keeps (D7): durable offload rows and the sync cursor need
        // a database. DuckDB left with the Parquet snapshot (D4).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Wire bytes and the vectors that pin them: GATT payloads, offload framing, Cairn-Sig
        // and the enrolment proof. No I/O of any kind, not even a URLSession type.
        .target(name: "CairnProtocol"),
        .testTarget(name: "CairnProtocolTests", dependencies: ["CairnProtocol"]),

        // Decisions: the link machine, the priming policy, the offload machine, the sync engine,
        // the server client and the display models. Pure, driven by events and fakes.
        .target(name: "CairnKit", dependencies: ["CairnProtocol"]),
        .testTarget(name: "CairnKitTests", dependencies: ["CairnKit"]),

        // Apple frameworks, each behind a CairnKit protocol: CoreBluetooth, Core Location,
        // the Secure Enclave, URLSession and GRDB.
        .target(name: "CairnRuntime", dependencies: [
            "CairnKit",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        // Small on purpose: the adapters hold no rules, so there is little here to test. What it
        // does cover is the one way an adapter can be silently wrong — a constant that CairnKit
        // spells out by hand, because it imports no Apple framework, drifting from the framework.
        .testTarget(name: "CairnRuntimeTests", dependencies: ["CairnRuntime"]),
    ]
)
