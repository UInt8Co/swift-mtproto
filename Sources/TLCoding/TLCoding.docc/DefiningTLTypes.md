# Defining TL types

Map TL constructors, boxed types and RPC functions onto Swift declarations.

## Structs — one TL constructor

A `struct` maps to a single TL constructor. Every stored property becomes a
field, serialized in declaration order, and ``TLObject()`` generates an
extension conforming to ``TLConstructed``:

```swift
extension User: TLConstructed, TLEncodable, TLDecodable {
  public static var tlConstructorID: UInt32 { 0xd23c81a3 }
  public func tlEncodeBare(to writer: inout TLWriter) { ... }   // fields only
  public init(tlBareFrom reader: inout TLReader) throws { ... }
  // The boxed tlEncode(to:) / init(tlFrom:) come from TLConstructed: they
  // prefix / validate the constructor number.
}
```

It also adds a memberwise initializer that leaves out the ``TLFlags()``
bitfields — those are recomputed on encode, so they are not a caller's
concern:

```swift
User(id: 42, firstName: "Ada")   // no `flags:` parameter
```

Declare an initializer of your own and the macro leaves it alone, so a
hand-written type keeps whatever API it wants. ``TLOmit()``ted properties *are*
parameters: they belong to the type, they just never reach the wire.

## Enums — one constructor per case

An `enum` maps to a TL *type* with several constructors; the associated values
are each constructor's fields. Decoding switches on the constructor number:

```swift
@TLObject
enum InputPeer: Equatable {
  case inputPeerEmpty                                        // inputPeerEmpty#7f3b18ea
  case inputPeerUser(userId: Int64, accessHash: Int64)
  @TLCase(id: 0xdbb371a1) case inputPeerSelf                 // explicit override
}
```

The generated `init(tlFrom:)` throws ``TLError/unexpectedConstructor(found:expected:)``
for an unknown number. Enums also expose `tlConstructorIDs` (all cases) and an
instance `tlConstructorID`.

## Multi-constructor types — ``TLType()``

A TL type whose constructors are full standalone ``TLObject()`` structs is
modeled as a ``TLType()`` enum instead. This is the shape `mtproto-gen-swift`
emits, because a constructor's conditional fields cannot be expressed as enum
associated values:

```swift
@TLObject(id: 0x7f3b18ea) struct InputPeerEmpty {}
@TLObject(id: 0xdde8a54c) struct InputPeerUser { var userId: Int64; var accessHash: Int64 }

@TLType
indirect enum InputPeer: Equatable {
  case inputPeerEmpty(InputPeerEmpty)
  case inputPeerUser(InputPeerUser)
}
```

Encoding writes the payload's boxed form; decoding switches on the payloads'
`tlConstructorID`s. Mark the enum `indirect` when constructors reference their
own type recursively — common in the Telegram API schema.

## RPC functions — ``TLObject(id:returning:)``

A functional combinator (an RPC request) pairs a serializable struct with the
type its boxed result decodes to, which is what ``TLFunction`` carries:

```swift
@TLObject(id: 0xa677244f, returning: SentCode.self)
struct SendCode { var phoneNumber: String }

func invoke<F: TLFunction>(_ f: F) async throws -> F.ReturnType {
  try F.ReturnType(tlData: try await transport.send(f.tlSerialized()))
}
```

For a *generic* wrapper (`invokeWithLayer#da9b0d0d layer:int query:!X = X`),
attribute arguments cannot reference the generic parameter. Declare the
conformance at the site and the macro generates only the encoder — the opaque
payload cannot be decoded statically:

```swift
@TLObject(id: 0xda9b0d0d)
struct InvokeWithLayer<Query: TLFunction>: TLFunction, Sendable {
  typealias ReturnType = Query.ReturnType
  var layer: Int32
  var query: Query
}
```

## Limitations

- The serialized field order is the property declaration order — keep it in
  sync with the schema being implemented.
- Optional properties must be ``TLConditional(bit:)``; the macro rejects them
  otherwise.
- Enum associated values cannot be optional; model a constructor with
  conditional fields as a struct payload.
- Fully generic TL (`{t:Type}`) is out of scope beyond the `query:!X`
  wrapper-function pattern above.
