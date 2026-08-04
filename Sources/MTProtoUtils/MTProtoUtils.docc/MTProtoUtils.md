# ``MTProtoUtils``

Small shared pieces the other modules need, with no dependencies of their own.

## Overview

``CRC32`` is the checksum MTProto uses in two unrelated places: TL constructor
numbers are the CRC32 of a normalized declaration, and the `full` transport
framing appends one over each frame's `length`, `seqno` and payload. It supports
both a one-shot and an incremental form, so a frame's checksum can accumulate
across non-contiguous regions without concatenating them first.

``TLInt53`` is a 64-bit integer confined to the range JavaScript represents
exactly (`-(2^53 - 1) ... (2^53 - 1)`). Telegram entity ids — users, chats,
channels — travel as a TL `long` but must stay inside it, and a JavaScript client
silently rounds one that does not. Use it wherever such an id is stored, minted or
passed around, and reach for ``TLInt53/rawValue`` only at the wire boundary, where
generated `long` fields expect a plain `Int64`. Pick the initializer by trust
level: ``TLInt53/init(validating:)`` throws (use it on anything that arrived from
outside), ``TLInt53/init(clamping:)`` clamps, and an integer literal traps at the
point of definition.

`hexEncodedString` on any byte sequence is the lowercase hex encoding. It is
hand-rolled because `String(format:)` needs full Foundation, which these modules
deliberately do not require.

## Topics

- ``CRC32``
- ``TLInt53``
