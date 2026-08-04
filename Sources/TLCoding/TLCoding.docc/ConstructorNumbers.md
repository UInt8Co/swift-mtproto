# Constructor numbers

Where the 32-bit constructor number comes from, and when to write it out.

## Overview

Per the TL specification a constructor number is the CRC32 of the constructor's
declaration. ``TLObject()`` derives that declaration from the Swift one:

- the type or case name is lowercased at the first letter (`InputPeer` →
  `inputPeer…`);
- property names become `snake_case` (`firstName` → `first_name`);
- types map to TL types — `Int32`/`UInt32` → `int`, `Int64`/`UInt64`/`Int` →
  `long`, `Double` → `double`, `String` → `string`, `Data` → `bytes`, `Bool` →
  `Bool`, ``TLInt128`` → `int128`, ``TLInt256`` → `int256`, `[T]` →
  `Vector<T>`, and any other ``TLObject()`` type keeps its Swift name.

This reproduces real Telegram constructor numbers whenever the Swift declaration
mirrors the schema (the tests check `user#d23c81a3` from the documentation and
`inputPeerEmpty#7f3b18ea` from the API schema).

## Prefer the schema's number

When interoperating with the official schema, pass the number from it explicitly
with ``TLObject(id:)`` — that is always authoritative, and immune to a Swift
declaration that drifts from the TL one. ``TLObject(schema:)`` is the middle
ground: it hashes a TL declaration given as a string, ignoring an inline
`#xxxxxxxx` number, a trailing `;` and parentheses.

``TLSchema/constructorID(forDeclaration:)`` exposes the same computation at
runtime.
