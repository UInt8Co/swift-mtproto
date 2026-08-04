# ``MTProtoBaseSchema``

The MTProto service schema — the auth-key handshake and the service messages —
generated as Swift.

## Overview

This is the low level of the protocol, below any API layer: `resPQ`,
`req_DH_params`, `p_q_inner_data`, `new_session_created`, `bad_msg_notification`,
`msgs_ack`, `future_salts`, `rpc_result`, `rpc_error`, and their companions.
Everything nests under the root `TL` namespace this module declares:

```swift
import MTProtoBaseSchema

let request = TL.ReqPqMulti(nonce: .random())
let response = try TL.ResPQ(tlData: bytes)
```

The module declares the root `TL` namespace enum, so an API schema generated on
top of it extends the same namespace — see `--root-namespace-module` in
`MTProtoGenKit`. Importing that schema then presents both layers as one `TL.*`
surface.

`--mode types` is deliberate: these combinators are handled by hand in a session
layer, not dispatched generically, and several are not representable as flat
generated structs at all.

## What is not here

`Scripts/generate-mtproto-schema.sh` regenerates the module, and drops from the
schema the pseudo-combinators a session layer must parse itself:

- `msg_container`, `message`, `msg_copy` — length-delimited framing;
- `http_wait` — references a type the schema does not define;
- `gzip_packed` — its result is the `Object` pseudo-type, which the generator
  treats as built-in (`TLAnyObject`).

The schema itself is merged from two sources: Telegram's authoritative
`mtproto-json`, plus the constructors real clients still send that it has since
dropped — most importantly the plain `p_q_inner_data#83c95aec`, without `dc`,
that GramJS-derived clients use during the handshake. `Scripts/merge-mtproto-schema.ts`
holds the policy: corefork wins, and a foreign constructor is only added when
corefork already models its result type.
