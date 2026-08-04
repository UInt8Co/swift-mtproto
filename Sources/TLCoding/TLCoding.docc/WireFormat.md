# The wire format

The runtime the macros generate against, and how each TL value is laid out.

## Overview

Every value has two forms. The **boxed** form (``TLEncodable/tlEncode(to:)``)
carries the 32-bit constructor number first, so the concrete constructor can be
recovered while decoding. The **bare** form
(``TLEncodable/tlEncodeBare(to:)``) is the fields alone, for when the
constructor is unambiguous from context.

For the TL primitives (`int`, `long`, `double`, `string`, `bytes`, `int128`,
`int256`) the two forms are identical, because fields of these types are always
declared bare in TL schemas.

## The runtime

- ``TLWriter`` / ``TLReader`` — little-endian buffers implementing the
  [serialization rules](https://core.telegram.org/mtproto/serialize): 4-byte
  aligned output; `string`/`bytes` with a 1-byte (≤ 253) or `0xFE` + 3-byte
  length prefix and zero padding; `int128`/`int256` as raw little-endian words.
  ``TLReader`` validates lengths and throws ``TLError``.
- ``TLEncodable`` / ``TLDecodable`` — the boxed and bare forms, plus the
  `tlSerialized()` / `init(tlData:)` conveniences.
- Primitives — `Int32`, `UInt32`, `Int64`, `UInt64`, `Int` (as `long`),
  `Double`, `String`, `Data`, ``TLInt128``, ``TLInt256`` (with `.random()` for
  handshake nonces).
- `Bool` — the boxed TL `Bool` type (`boolTrue#997275b5` / `boolFalse#bc799737`).
- `Array` — TL `Vector t` (`vector#1cb5c415 count elements`); the bare form drops
  the constructor word.
- ``TLAnyObject`` — the `Object` pseudo-type, held as raw boxed bytes.

Everything composes: vectors of objects, nested objects, enums inside vectors.

```swift
// resPQ#05162463 from the MTProto handshake:
@TLObject(id: 0x05162463)
struct ResPQ {
  var nonce: TLInt128
  var serverNonce: TLInt128
  var pq: Data
  var serverPublicKeyFingerprints: [Int64]
}
```

## Bare vectors and bare elements

A vector has two independent "bare" dimensions, and TL spells them separately:

| TL | Attributes | On the wire |
|---|---|---|
| `Vector<T>` | — | `0x1cb5c415`, count, boxed elements |
| `Vector<%t>` | ``TLBareElements()`` | `0x1cb5c415`, count, bare elements |
| `vector<t>` | ``TLBare()`` | count, boxed elements |
| `vector<%t>` | ``TLBare()`` + ``TLBareElements()`` | count, bare elements |

Getting this wrong is not a decode error but a protocol one: a peer reads the
extra constructor word as the next field. `future_salts`' `salts:vector<future_salt>`
is the canonical case — bare elements inside a bare vector.
