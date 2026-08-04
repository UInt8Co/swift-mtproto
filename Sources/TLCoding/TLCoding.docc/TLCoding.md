# ``TLCoding``

Serialize Swift types to and from MTProto's binary format with macros.

## Overview

[TL](https://core.telegram.org/mtproto/TL) is the type language MTProto is
described in, and [TL serialization](https://core.telegram.org/mtproto/serialize)
its binary encoding. Annotate a type with ``TLObject()`` and it gains that
encoding: constructor numbers, little-endian 32-bit-aligned layout,
length-prefixed padded strings, vectors, and `flags.N?Type` conditional fields.

```swift
import TLCoding

// TL: user id:int first_name:string last_name:string = User
// (constructor user#d23c81a3, derived automatically)
@TLObject
struct User: Equatable {
  var id: Int32
  var firstName: String
  var lastName: String
}

let data = User(id: 42, firstName: "Ada", lastName: "Lovelace").tlSerialized()
let user = try User(tlData: data)
```

The macros expand against the small runtime this module also provides —
``TLWriter``/``TLReader`` and the ``TLEncodable``/``TLDecodable`` protocols — so
a hand-written type and a generated one meet the same wire format.

## Topics

### Essentials

- <doc:DefiningTLTypes>
- <doc:ConditionalFields>
- <doc:ConstructorNumbers>
- <doc:WireFormat>

### Declaring types

- ``TLObject()``
- ``TLObject(id:)``
- ``TLObject(id:returning:)``
- ``TLObject(schema:)``
- ``TLType()``
- ``TLCase(id:)``
- ``TLCase(schema:)``

### Declaring fields

- ``TLFlags()``
- ``TLConditional(bit:)``
- ``TLConditional(_:bit:)``
- ``TLBare()``
- ``TLBareElements()``
- ``TLOmit()``
- ``TLFlagsEquatable()``

### Runtime

- ``TLWriter``
- ``TLReader``
- ``TLEncodable``
- ``TLDecodable``
- ``TLCodable``
- ``TLConstructed``
- ``TLFunction``
- ``TLAnyObject``
- ``TLInt128``
- ``TLInt256``
- ``TLSchema``
- ``TLError``
- ``tlVectorConstructorID``
