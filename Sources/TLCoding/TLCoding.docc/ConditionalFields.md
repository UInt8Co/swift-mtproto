# Conditional fields and equality

Model TL's `flags:#` bitfields, and compare values that carry them.

## Overview

```swift
// TL: dialog flags:# pinned:flags.2?true peer_id:long top_message:flags.0?int = Dialog
@TLObject
@TLFlagsEquatable
struct Dialog: Equatable {
  @TLFlags var flags: UInt32 = 0
  @TLConditional(bit: 2) var pinned: Bool = false   // flags.2?true — bit only
  var peerID: Int64
  @TLConditional(bit: 0) var topMessage: Int32?     // flags.0?int
}
```

On encode the bitfield is recomputed from the actual fields: a non-`nil`
optional, or a `true` presence bool, sets its bit. On decode the raw bitfield is
stored back into the ``TLFlags()`` property, unknown bits included — but those
are not re-emitted.

A ``TLFlags()`` property must be declared before the fields that reference it;
that is its position on the wire. Several bitfields per type are supported —
reference one by name with ``TLConditional(_:bit:)``, e.g.
`@TLConditional("flags2", bit: 0)`.

## Equality

Because decoding stores the bitfield exactly as it arrived while encoding
recomputes it, two values that mean the same thing can carry different bits, and
the compiler's memberwise `==` would call them unequal. ``TLFlagsEquatable()``
generates one that compares the logical fields and skips the bitfields.

A struct with no bitfield does not need it — the synthesized memberwise `==` is
already correct there, and attaching it is an error.

It is a separate attribute rather than part of ``TLObject()`` deliberately. A
macro that declares it introduces `==` makes the compiler *derive* the
`Equatable` witness and ignore any explicitly declared operator — silently, and
even for types the macro adds nothing to. Keeping it opt-in means ``TLObject()``
alone never changes what a hand-written `==` does; declaring both is a compile
error.
