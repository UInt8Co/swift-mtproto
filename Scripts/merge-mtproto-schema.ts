// Merges the corefork MTProto schema with the handful of legacy constructors
// that GramJS / telegram-tt still send but corefork has dropped — most
// importantly the plain `p_q_inner_data#83c95aec` (no `dc` field) that
// telegram-tt's Authenticator builds and RSA_PAD-wraps. Without it the RSA block
// decrypts fine but its payload cannot be decoded, and the handshake fails with a
// misleading "RSA key mismatch".
//
// telegram-tt's low-level schema lives as a `.tl` string in
// `src/lib/gramjs/tl/schemaTl.ts`; Scripts/generate-mtproto-schema.sh extracts
// that template literal into Schemas/telegram-tt-mtproto.tl and passes it here.
//
// Merge policy — corefork is authoritative; a telegram-tt entry is ADDED only
// when BOTH:
//   1. its constructor id is not already in corefork (dedupe by id), and
//   2. its result *type already exists in corefork*.
// Rule (2) pulls in the missing variants of types corefork already models
// (P_Q_inner_data, Server_DH_Params, ResPQ, …) while rejecting telegram-tt's
// MTProxy / fake-TLS extras (ipPort, accessPointRule, tlsClientHello, tlsBlock*,
// help.configSimple) that would introduce brand-new types alien to the base
// schema. Entries without an explicit `#id` (the fake-TLS combinators) are
// skipped outright.
//
// GramJS renders TL `bytes` as `string` throughout this schema, so an added
// entry's `string` fields are mapped back to `bytes`. Genuine TL strings (only
// rpc_error.error_message in this layer) live on types corefork already owns,
// so they are never introduced by an addition and keep corefork's `string`.
//
// The pseudo-combinators that cannot be represented as flat generated structs
// (msg_container, message, msg_copy, http_wait) are excluded last, after the
// merge, so a telegram-tt copy of one can't sneak back in.
//
// Usage: deno run --allow-read --allow-write merge-mtproto-schema.ts \
//   <corefork.json> <telegram-tt.tl> <out.json>

interface Param {
  name: string
  type: string
}
interface Constructor {
  id: string
  predicate: string
  params: Param[]
  type: string
}
interface Method {
  id: string
  method: string
  params: Param[]
  type: string
}
interface Schema {
  constructors: Constructor[]
  methods: Method[]
}

const EXCLUDE = new Set(["msg_container", "message", "msg_copy", "http_wait"])

// The generator parses `id` as a signed 32-bit decimal; `.tl` writes it as an
// unsigned hex hash after `#`.
function signedId(hex: string): string {
  const n = Number.parseInt(hex, 16)
  return (n > 0x7fffffff ? n - 0x100000000 : n).toString()
}

// GramJS `string` is TL `bytes` everywhere in this low-level schema.
function mapType(t: string): string {
  return t === "string" ? "bytes" : t
}

// Parses GramJS's `.tl` text into constructors and methods. Lines are types by
// default; `---functions---` switches to methods, `---types---` switches back.
function parseTL(text: string): Schema {
  const constructors: Constructor[] = []
  const methods: Method[] = []
  let inMethods = false
  for (const raw of text.split("\n")) {
    const line = raw.trim()
    if (line === "") continue
    if (line === "---functions---") { inMethods = true; continue }
    if (line === "---types---") { inMethods = false; continue }

    const [defPart, typePart] = line.replace(/;$/, "").split(" = ")
    if (typePart === undefined) continue
    const type = typePart.trim()
    const tokens = defPart.trim().split(/\s+/)
    const head = tokens[0]
    if (!head.includes("#")) continue // fake-TLS combinator without a canonical id
    const [predicate, hex] = head.split("#")
    const id = signedId(hex)
    const params: Param[] = []
    for (const tok of tokens.slice(1)) {
      const idx = tok.indexOf(":")
      if (idx < 0) continue
      params.push({ name: tok.slice(0, idx), type: tok.slice(idx + 1) })
    }
    if (inMethods) methods.push({ id, method: predicate, params, type })
    else constructors.push({ id, predicate, params, type })
  }
  return { constructors, methods }
}

const [coreforkPath, tlPath, outPath] = Deno.args
const corefork = JSON.parse(await Deno.readTextFile(coreforkPath)) as Schema
const telegram = parseTL(await Deno.readTextFile(tlPath))

const knownIds = new Set<string>([
  ...corefork.constructors.map((c) => c.id),
  ...corefork.methods.map((m) => m.id),
])
const knownTypes = new Set<string>(corefork.constructors.map((c) => c.type))

function mapParams(params: Param[]): Param[] {
  return params.map((p) => ({ name: p.name, type: mapType(p.type) }))
}

const addedConstructors: string[] = []
for (const c of telegram.constructors) {
  if (knownIds.has(c.id) || !knownTypes.has(c.type)) continue
  corefork.constructors.push({ ...c, params: mapParams(c.params) })
  knownIds.add(c.id)
  addedConstructors.push(c.predicate)
}

const addedMethods: string[] = []
for (const m of telegram.methods) {
  if (knownIds.has(m.id) || !knownTypes.has(m.type)) continue
  corefork.methods.push({ ...m, params: mapParams(m.params) })
  knownIds.add(m.id)
  addedMethods.push(m.method)
}

corefork.constructors = corefork.constructors.filter((c) => !EXCLUDE.has(c.predicate))
corefork.methods = corefork.methods.filter((m) => !EXCLUDE.has(m.method))

await Deno.writeTextFile(outPath, JSON.stringify(corefork, null, 1) + "\n")
console.log(
  `merged telegram-tt: +${addedConstructors.length} constructors ` +
    `[${addedConstructors.join(", ")}], +${addedMethods.length} methods ` +
    `[${addedMethods.join(", ")}]`,
)
