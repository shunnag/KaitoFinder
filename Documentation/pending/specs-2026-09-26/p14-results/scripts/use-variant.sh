#!/bin/bash
# Usage: use-variant.sh <n>  — point the harness manifest at ../S<n>/{GyoshukuKit,KaitoKit}
set -euo pipefail
n=$1
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
cat > "$here/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
// P14 harness: variant S=${n} MiB
let package = Package(
    name: "P14Harness",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../S${n}/GyoshukuKit"), .package(path: "../S${n}/KaitoKit")],
    targets: [
        .executableTarget(name: "P14Harness", dependencies: [
            .product(name: "GyoshukuKit", package: "GyoshukuKit"),
            .product(name: "KaitoKit", package: "KaitoKit"),
        ])
    ],
    swiftLanguageModes: [.v5]
)
MANIFEST
