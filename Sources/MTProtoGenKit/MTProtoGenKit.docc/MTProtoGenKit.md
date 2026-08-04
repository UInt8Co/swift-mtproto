# ``MTProtoGenKit``

Turn Telegram's TL schema into Swift built on `TLCoding`.

## Overview

This module parses the official
[TL schema](https://corefork.telegram.org/schema) (JSON), resolves every TL name
onto a deterministic Swift one, and emits sources with swift-syntax. The
`mtproto-gen-swift` executable in `Sources/MTProtoGenSwiftCLI` is a thin command
line over it:

```sh
swift run mtproto-gen-swift \
  --mode client \
  --output Sources/MyTelegramSchema \
  [--schema-url https://corefork.telegram.org/schema/json] \
  [--visibility public] \
  [--split-modules MyTelegramSchema]
```

- `--mode types|client` (required) — the schema types and request structs alone,
  or the async RPC client alongside them.
- `--output` (required) — directory for the generated sources. The `Types/`,
  `Methods/`, `Client/` and `Support/` subdirectories are owned (and replaced) by
  the generator; everything else is untouched.
- `--schema-url` — defaults to `https://corefork.telegram.org/schema/json`; also
  accepts `file://` URLs and plain paths.
- `--visibility public|package|internal|private` — access level of every
  generated declaration (default `public`).
- `--method <tl-name>` (repeatable) / `--methods-file <path>` — generate only
  these methods; see <doc:SelectingMethods>.
- `--exclude-namespace <tl-namespace>` (repeatable) — see
  <doc:ExcludingNamespaces>.
- `--root-namespace-module <module>` — see <doc:ExtendingASchema>.
- `--split-modules <umbrella-module>` — see <doc:SplittingIntoModules>.

Generation is deterministic: the same schema bytes and options produce
byte-identical files. Every emitted file is re-parsed with SwiftParser, and
generation fails on any syntax error.

## Topics

### Generating

- <doc:GeneratedShape>
- <doc:SelectingMethods>
- <doc:ExcludingNamespaces>
- <doc:ExtendingASchema>
- <doc:SplittingIntoModules>
- <doc:ExtendingEmission>

### Running a generation

- ``MTProtoGenerator``
- ``GeneratorOptions``
- ``GeneratedFile``
- ``GeneratedModule``
- ``GeneratedPackage``
- ``MethodManifest``
- ``GeneratorError``

### The schema model

- ``TLSchemaJSON``
- ``ResolvedSchema``
- ``SwiftName``
- ``TLField``
- ``TLValueType``
