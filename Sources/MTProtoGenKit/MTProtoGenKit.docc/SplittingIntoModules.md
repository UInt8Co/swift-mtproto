# Splitting into modules

Emit one schema as several modules, so a schema change rebuilds a fraction of it.

## Overview

A full API schema is thousands of files, and every build system caches Swift at
module granularity: one added RPC recompiles all of them. `--split-modules
<umbrella-module>` emits the same declarations as several modules instead, one
directory each under `--output`:

| Module | Contents | Depends on |
|---|---|---|
| `<U>Support` | the root `TL` namespace (or its re-export) and the namespace enums | — |
| `<U>Types` | every schema type | Support |
| `<U>Methods<Namespace>` | one TL namespace's request structs | Types |
| `<U>Client`, `<U>Client<Namespace>` | with `--mode client`, the `TLClient` and its per-namespace methods | Types, the namespace's methods |
| `<U>` | nothing but `@_exported import`s of all of the above | everything |

Consumers import only the umbrella, so splitting is not a source-breaking change:
`import <U>` still presents the whole `TL.*` surface.

The partition follows the schema's own structure — a TL namespace — and never
file counts or sizes, so a declaration moves between modules only when the schema
moves it. That is what makes the cache hit: adding an RPC rebuilds its
namespace's module and nothing else. Dependencies are likewise declared per
module rather than discovered per file, so a new reference inside an existing
module cannot churn its dependents.

## The manifest

Alongside the sources the generator writes ``GeneratedPackage/manifestFileName``
(`modules.json`), listing each module's name, directory and dependencies. Point a
small script at it to write the targets into your build manifests — the module
set follows the schema, so a namespace that comes and goes should not need a hand
edit.
