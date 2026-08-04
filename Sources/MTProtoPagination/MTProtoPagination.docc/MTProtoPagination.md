# ``MTProtoPagination``

Telegram's vector hashing and the offset/limit paging rules, expressed once.

## Overview

Both mechanisms are specified at <https://corefork.telegram.org/api/offsets>.
Getting either subtly wrong is invisible in a single call and obvious over a
session — a list that never updates, or one that repeats a page forever — so they
live here rather than in each list RPC.

## Vector hashing

Many RPCs returning a list let the caller send the hash of its cached copy and
get a `*NotModified` constructor back when nothing changed. The hash is a 64-bit
XOR/shift/add fold, identical across TDLib, mtcute and the official clients:

```
hash = 0
for id in ids:
    hash = hash ^ (hash >> 21)
    hash = hash ^ (hash << 35)
    hash = hash ^ (hash >>  4)
    hash = hash + id
```

All arithmetic is unsigned 64-bit — wrapping add, logical shifts — and the result
is reinterpreted as a signed `Int64` for the wire's `hash:long`. Order matters:
fold ids in the order the peer folds them. ``VectorHash`` does it incrementally,
or `VectorHash.compute(_:)` in one call.

Lists keyed by strings (emoji reactions, language packs) convert each string to a
long first — the first 8 bytes of its MD5 digest, big-endian — via
``VectorHash/longID(of:)``, then fold as usual.

``VectorHashState`` is the decision itself: either the cached copy is current, or
it is stale and the freshly computed hash must be echoed in the full response so
the peer can cache it. A hash of `0` is the conventional "I have no copy"
sentinel, so it never matches — even when the real hash of an empty list happens
to be `0`.

## Paging

``Pagination/clampedLimit(_:min:max:)`` bounds a wire `limit:int`; the
`default:`-taking overload is for the RPCs whose callers send `0` to mean "your
choice". Clamp before the value reaches a store.

``Pagination/page(_:offset:limit:)`` and ``Pagination/after(_:offsetId:id:)``
implement the two schemes — a plain index offset, and resuming after a cursor
element for a list that grows while being read. They operate on an
already-materialized collection: a static list, or one page a store already
returned. A database-backed list should page inside the query (`LIMIT`/`OFFSET`,
or a keyset `WHERE id < offset_id`), never by loading every row and slicing here.

## Topics

### Hashing

- ``VectorHash``
- ``VectorHashState``

### Paging

- ``Pagination``
