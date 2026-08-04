#!/usr/bin/env bash
#
# Regenerates the low-level MTProto service schema (the auth-key handshake and
# the service messages) into the MTProtoBaseSchema module. This module also
# declares the root `TL` namespace, which a generated API-layer module extends
# and re-exports via `--root-namespace-module MTProtoBaseSchema`.
#
# Sources, merged by Scripts/merge-mtproto-schema.ts:
#   - corefork:     https://corefork.telegram.org/schema/mtproto-json  (authoritative)
#   - telegram-tt:  https://github.com/Ajaxy/telegram-tt
#                   src/lib/gramjs/tl/schemaTl.ts                       (legacy adds)
#
# corefork is authoritative; the merge only adds telegram-tt constructors whose
# result type corefork already models — most importantly the plain
# `p_q_inner_data#83c95aec` (no `dc`) that telegram-tt / GramJS actually send
# during the handshake, which corefork's current schema has dropped. See
# merge-mtproto-schema.ts for the full policy.
#
# The raw inputs are cached in Schemas/ (refreshed with --fetch). The merged,
# curated copy (Schemas/mtproto-generated.json) additionally drops the
# transport-framing pseudo-combinators that cannot be represented as flat
# generated structs and are instead parsed by hand in a session layer:
#
#   msg_container, message, msg_copy  — length-delimited, parsed manually
#   http_wait                         — references the dangling `HttpWait` type
#
# `gzip_packed` is dropped automatically: its result type is the `Object`
# pseudo-type, which the generator treats as built-in (`TLAnyObject`).
set -euo pipefail
cd "$(dirname "$0")/.."

COREFORK_URL="https://corefork.telegram.org/schema/mtproto-json"
TELEGRAM_TT_URL="https://raw.githubusercontent.com/Ajaxy/telegram-tt/master/src/lib/gramjs/tl/schemaTl.ts"
RAW="Schemas/mtproto.json"
TELEGRAM_TL="Schemas/telegram-tt-mtproto.tl"
CURATED="Schemas/mtproto-generated.json"
DEST="Sources/MTProtoBaseSchema"

if [[ "${1:-}" == "--fetch" ]]; then
  echo "Fetching $COREFORK_URL"
  "$HOME/deno" eval '
    const r = await fetch("'"$COREFORK_URL"'");
    await Deno.writeTextFile("'"$RAW"'", JSON.stringify(JSON.parse(await r.text()), null, 1) + "\n");
  '
  echo "Fetching $TELEGRAM_TT_URL"
  "$HOME/deno" eval '
    const r = await fetch("'"$TELEGRAM_TT_URL"'");
    const src = await r.text();
    // schemaTl.ts is `export default `<.tl text>`;` — extract the template literal.
    const body = src.slice(src.indexOf("`") + 1, src.lastIndexOf("`"));
    await Deno.writeTextFile("'"$TELEGRAM_TL"'", body.trimEnd() + "\n");
  '
fi

"$HOME/deno" run --allow-read --allow-write \
  Scripts/merge-mtproto-schema.ts "$RAW" "$TELEGRAM_TL" "$CURATED"

swift build -j 1 --product mtproto-gen-swift
SCRATCH="$(mktemp -d)"
.build/debug/mtproto-gen-swift \
  --schema-url "$CURATED" --output "$SCRATCH" --mode types

mkdir -p "$DEST"
rm -rf "$DEST/Types" "$DEST/Methods" "$DEST/Support"
cp -r "$SCRATCH/Types" "$DEST/Types"
cp -r "$SCRATCH/Methods" "$DEST/Methods"
cp -r "$SCRATCH/Support" "$DEST/Support"
rm -rf "$SCRATCH"
echo "Regenerated MTProto base schema into $DEST"
