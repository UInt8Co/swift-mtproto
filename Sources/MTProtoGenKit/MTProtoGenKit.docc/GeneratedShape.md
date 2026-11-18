# What is generated

The Swift each TL construct becomes, and the naming rules behind it.

## Overview

Everything nests under a root `TL` namespace enum, with one nested caseless enum
per TL namespace (`TL.Auth`, `TL.Messages`, …). Generated references are always
`TL.`-qualified, so a sibling name can never shadow them.

| TL construct | Swift |
|---|---|
| constructor `auth.sentCode#5e002502 … = auth.SentCode` | `@TLObject(id:)` struct `TL.Auth.SentCode` (file `Types/auth.SentCode.swift`) |
| type with several constructors | `@TLType enum TL.Auth.SentCodeType`, one case per constructor carrying its struct; only a case whose struct leads back to the enum by value is `indirect` (see <doc:GeneratedShape#Recursive-types>) |
| type with one constructor | the struct itself, referenced directly |
| `flags:#` / `field:flags.N?Type` / `flags.N?true` | `@TLFlags` / `@TLConditional` properties, plus `@TLFlagsEquatable` for an `==` that ignores the raw bitfields |
| method `auth.sendCode#… = auth.SentCode` | `@TLObject(id:returning:)` struct `TL.Auth.SendCode` conforming to `TLFunction`, with `tlMethodName` `"auth.sendCode"` (file `Methods/auth.sendCode.swift`) |
| generic wrappers (`invokeWithLayer`, `query:!X = X`) | generic structs like `TL.InvokeWithLayer<Query: TLFunction>` conforming to `TLFunctionWrapper`, encode-only |
| `--mode client` | `TLClient` over a caller-provided `TLClientTransport`, with an async function per method: `try await client.auth.sendCode(…)` |

The generated code depends only on `TLCoding`. Bring your own transport:
implement `TLClientTransport` and hand `TLClient` a connection. The seam is
typed — `invoke<Function: TLFunction>(_:) async throws -> Function.ReturnType` —
so only the transport at the bottom of a chain serializes the function and
decodes the reply. Transports layered above it (logging, retries, observing the
peers in a result) receive the typed function and result, read
`Function.tlMethodName`, and see through `invokeWith…` wrappers with
`tlInnermostFunction`, without re-parsing bytes.

A generic method must be a `query:!X = X` wrapper — exactly one `!X` parameter,
named `query`, and the result `X` — so it can be a `TLFunctionWrapper`; the
generator rejects any other generic shape.

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

## Recursive types

A type enum's cases hold their constructor structs inline, so a case is
`indirect` only when its struct leads back to the same enum by value — through a
field, a `flags.N?` optional, or other structs and enums stored inline. A `Vector`
field stores its elements on the heap and ends the chain, so `Vector<Block>` inside
a `Block` constructor needs no `indirect`. The generator finds these cases from the
strongly connected components of the inline-reference graph; every other case keeps
its payload unboxed. Where `indirect` sits does not change how a value is built or
matched.
