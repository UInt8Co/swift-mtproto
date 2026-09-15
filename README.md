# swift-mtproto

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-mtproto%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/UInt8Co/swift-mtproto)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FUInt8Co%2Fswift-mtproto%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/UInt8Co/swift-mtproto)

The foundations of [MTProto](https://corefork.telegram.org/mtproto) in Swift: TL
serialization, the crypto primitives the protocol is built on, the MTProto
service schema, and a code generator that turns Telegram's TL schema into Swift.

This package does not include a transport implementation. A NIO-based transport
implementation with a minimum client implementation is available at 
[UInt8Co/swift-nio-mtproto](https://github.com/UInt8Co/swift-nio-mtproto).

```swift
.package(url: "https://github.com/UInt8Co/swift-mtproto", from: "2.0.0")
```

## Modules

| Module | What it is |
|---|---|
| `TLCoding` | The TL wire format as Swift macros: annotate a type with `@TLObject` and it gains constructor numbers, 32-bit-aligned layout, length-prefixed strings, vectors and `flags.N?` conditionals |
| `MTProtoGenKit` | The `mtproto-gen-swift` generator: TL schema JSON → Swift built on `TLCoding`, optionally split across modules for build caching |
| `MTProtoBaseSchema` | The generated MTProto service schema — the auth-key handshake and service messages — and the root `TL` namespace an API schema extends |
| `MTProtoCrypto` | AES-IGE, the handshake and message KDFs (MTProto 1.0 and 2.0), RSA (raw and `RSA_PAD`), PQ factoring, SRP-6a for 2FA (both the server and the client half), and a constant-time comparison |
| `MTProtoPagination` | Telegram's vector-hash / `*NotModified` protocol and offset/limit paging math, per [api/offsets](https://corefork.telegram.org/api/offsets) |
| `MTProtoUtils` | The dependency-free shared bits: CRC32, hex coding, and `TLInt53` (web-safe 53-bit ids) |

## Generating a schema

```sh
swift run mtproto-gen-swift --mode client --output Sources/MyTelegramSchema
```

Everything nests under a root `TL` namespace: constructors become `@TLObject`
structs, multi-constructor types become `@TLType` enums, and RPC methods become
`TLFunction` request structs carrying their result type. With `--mode client` you
also get a `TLClient` exposing every method as an `async` function grouped by
namespace — `try await client.auth.sendCode(…)` — over a `TLClientTransport` you
supply.

`Scripts/generate-mtproto-schema.sh` regenerates `MTProtoBaseSchema` itself.

## Documentation

Each module carries a DocC catalog — method selection, the module split, the wire
format, the crypto pieces and the rest are documented there:

```sh
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target TLCoding --output-path ./docs
```

(That needs [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin)
added to your checkout, or Xcode's *Build Documentation*.) The sources are
`Sources/<Module>/<Module>.docc`, and read fine as Markdown on their own.

## Platforms

macOS 15+, iOS 18+, tvOS 18+, watchOS 11+, and Linux (glibc or musl). Swift 6.3
toolchain, language mode 6.

## License

MIT. See [LICENSE](LICENSE).
