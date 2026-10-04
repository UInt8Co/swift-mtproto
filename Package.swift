// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-mtproto",
  platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .macCatalyst(.v18)],
  products: [
    .library(name: "MTProtoUtils", targets: ["MTProtoUtils"]),
    .library(name: "TLCoding", targets: ["TLCoding"]),
    .library(name: "MTProtoCrypto", targets: ["MTProtoCrypto"]),
    .library(name: "MTProtoBaseSchema", targets: ["MTProtoBaseSchema"]),
    .library(name: "MTProtoPagination", targets: ["MTProtoPagination"]),
    .library(name: "MTProtoGenKit", targets: ["MTProtoGenKit"]),
    .executable(name: "mtproto-gen-swift", targets: ["MTProtoGenSwiftCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
  ],
  targets: [
    .target(
      name: "MTProtoUtils"
    ),
    .macro(
      name: "TLCodingMacros",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "TLCoding",
      dependencies: ["TLCodingMacros", "MTProtoUtils"]
    ),
    .testTarget(
      name: "TLCodingTests",
      dependencies: ["TLCoding", "MTProtoUtils"]
    ),
    // The TL → Swift code generator. Emits the schema types and, with
    // `--mode client`, the async RPC client.
    .target(
      name: "MTProtoGenKit",
      dependencies: [
        .product(name: "SwiftBasicFormat", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "MTProtoGenKitTests",
      dependencies: ["MTProtoGenKit"]
    ),
    .executableTarget(
      name: "MTProtoGenSwiftCLI",
      dependencies: [
        "MTProtoGenKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
    .target(
      name: "MTProtoBaseSchema",
      dependencies: ["TLCoding"]
    ),
    .target(
      name: "MTProtoCrypto",
      dependencies: [
        "MTProtoUtils",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "CryptoExtras", package: "swift-crypto"),
      ]
    ),
    .testTarget(
      name: "MTProtoCryptoTests",
      dependencies: ["MTProtoCrypto"]
    ),
    // Vector hashing (`*NotModified` short-circuits) and offset/limit paging
    // math. Crypto is only for the MD5 string-id → long rule the spec mandates.
    .target(
      name: "MTProtoPagination",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .testTarget(
      name: "MTProtoPaginationTests",
      dependencies: ["MTProtoPagination"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
