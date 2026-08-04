# Extending another schema

Generate a schema whose root `TL` namespace already lives in another module.

## Overview

Every generated declaration nests under one root `TL` namespace enum, so two
schemas generated into two modules would each declare their own `TL` — and a
consumer importing both could not name either. `--root-namespace-module <module>`
resolves it: the named module owns `TL`, and this run extends it.

Concretely, `Support/Namespaces.swift` re-exports that module instead of
redeclaring `TL`, and every generated file imports it. Importing the extending
module therefore still presents the complete `TL.*` surface.

This is how `MTProtoBaseSchema` and an API schema coexist: the base module — the
handshake and service messages — declares `TL`, and the API schema is generated
with `--root-namespace-module MTProtoBaseSchema` on top of it.
