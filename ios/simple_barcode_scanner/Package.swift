// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "simple_barcode_scanner",
  platforms: [
    .iOS("12.0")
  ],
  products: [
    .library(name: "simple-barcode-scanner", targets: ["simple_barcode_scanner"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "simple_barcode_scanner",
      dependencies: [],
      resources: [
        .process("Resources")
      ]
    )
  ]
)
