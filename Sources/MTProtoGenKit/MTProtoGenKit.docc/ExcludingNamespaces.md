# Excluding vendor namespaces

Drop the entries a third-party schema splices in under its own namespace.

## Overview

Schemas published by clients carry their own additions: mtcute ships
`mtcute.dummyUpdate`, `mtcute.customMethod` and friends. They are
client-internal and must never reach generated code, but a schema is easier to
keep verbatim than to pre-scrub. `--exclude-namespace mtcute` drops them.

It matches whole namespaces, not prefixes, and applies **before name
resolution** — which is the part that matters. A vendor namespace left in place
would contribute a namespace enum, could add a constructor to a real boxed type's
`@TLType` enum, and could claim a Swift name a real declaration wants, pushing it
to a `_` suffix. Filtering at ingestion means excluding a namespace produces
byte-identical output to a schema that never contained it.

``TLSchemaJSON/excluding(namespaces:)`` is the filter, and it runs as part of
every schema's ingestion — including a schema an additional emitter brings in, so
nothing can slip in through a side door.
