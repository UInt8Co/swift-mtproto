# Extending emission

Add your own generated declarations to a run, through the `GeneratorInternals`
SPI.

## Overview

A project may want declarations this package does not emit — an adapter layer, a
second schema's bindings, declarations for an older API layer. Emission and layout
are separate steps, so such an emitter appends its own files to the base emission
and hands the whole set back for assembly. The output is then identical to
generating everything in one pass, basename uniquing and syntax validation
included.

```swift
@_spi(GeneratorInternals) import MTProtoGenKit

let generator = MTProtoGenerator(options: options)
let resolved = try generator.parse(schemaData: schemaData)
let plan = ModuleSplitPlan(
  umbrella: "MySchema", rootNamespaceModule: nil,
  methodNamespaces: resolved.methodsByNamespace.map(\.namespace),
  clientNamespaces: [],
  aggregate: "Extras", extraStrippedPathPrefixes: ["Extras/"])

var emitted = try generator.baseEmission(resolved: resolved, imports: plan.imports(for:))
emitted += try myOwnEmission(resolved, imports: plan.imports(for:))
let package = try generator.assemblePackage(emitted, plan: plan)
```

Start from `parse(schemaData:)` rather than decoding the JSON yourself: it is the
shared ingestion step that drops the excluded namespaces before names are
resolved. Apply your own method selection afterwards if it needs to consider names
the primary schema does not have.

The SPI exposes what such an emitter needs: ``ResolvedSchema``'s reference tables
and type resolution, `SwiftFile` rendering, `objectStructDecl` for `@TLObject`
structs, the `Naming` rules, and `ModuleGroup` / `ModuleSplitPlan` for layout.

## Placing the extra files

An emitter's files may join an existing module — a declaration that belongs with
the requests it refers to — or form one of their own. `ModuleGroup.aggregate` is
that module: it comes last and may reference every other one. Paths are written as
if for a single-module run (`Extras/Foo.swift`); `extraStrippedPathPrefixes` tells
a split run to strip that prefix, wherever those files land.

Being SPI, none of this carries the package's API-stability promise — it can
change between minor versions.
