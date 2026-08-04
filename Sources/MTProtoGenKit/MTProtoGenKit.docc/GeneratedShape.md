# What is generated

The Swift each TL construct becomes, and the naming rules behind it.

## Overview

Everything nests under a root `TL` namespace enum, with one nested caseless enum
per TL namespace (`TL.Auth`, `TL.Messages`, …). Generated references are always
`TL.`-qualified, so a sibling name can never shadow them.

| TL construct | Swift |
|---|---|
| constructor `auth.sentCode#5e002502 … = auth.SentCode` | `@TLObject(id:)` struct `TL.Auth.SentCode` (file `Types/auth.SentCode.swift`) |
| type with several constructors | `@TLType indirect enum TL.Auth.SentCodeType`, one case per constructor carrying its struct |
| type with one constructor | the struct itself, referenced directly |
| `flags:#` / `field:flags.N?Type` / `flags.N?true` | `@TLFlags` / `@TLConditional` properties, plus `@TLFlagsEquatable` for an `==` that ignores the raw bitfields |
| method `auth.sendCode#… = auth.SentCode` | `@TLObject(id:returning:)` struct `TL.Auth.SendCode` conforming to `TLFunction` (file `Methods/auth.sendCode.swift`) |
| generic wrappers (`invokeWithLayer`, `query:!X`) | generic structs like `TL.InvokeWithLayer<Query: TLFunction>`, encode-only |
| `--mode client` | `TLClient` over a caller-provided `TLClientTransport`, with an async function per method: `try await client.auth.sendCode(…)` |

The generated code depends only on `TLCoding`. Bring your own transport:
implement `TLClientTransport` and hand `TLClient` a connection.

## Naming

Naming is mechanical and collision-safe:

- namespaces capitalize (`auth` → `TL.Auth`), and members capitalize their local
  name;
- a multi-constructor type's enum takes a `Type` suffix, which keeps it clear of
  the same-named constructor (`user` / `User`) TL types so often have;
- `snake_case` fields become `camelCase`; Swift keywords are backticked, and
  `self` becomes `self_` (a backticked `self` parameter would shadow the instance
  inside the initializer);
- any name that would collide with a namespace enum or shadow a runtime type gets
  `_` appended — the `updates` constructor becomes `TL.Updates_`, because of the
  `updates.*` namespace.

File names mirror the TL names and stay flat. SwiftPM derives object file names
from source basenames, and build products may land on a case-insensitive
filesystem, so every basename is made unique ignoring case: later claimants (in
emission order, which is deterministic) get `_` appended.
