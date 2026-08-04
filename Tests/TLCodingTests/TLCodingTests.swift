import Foundation
import Testing

@testable import TLCoding

// MARK: - Fixtures

/// The example from https://core.telegram.org/mtproto/TL:
/// `user#d23c81a3 id:int first_name:string last_name:string = User;`
/// The constructor number is derived automatically from the Swift declaration.
@TLObject
struct User: Equatable {
  var id: Int32
  var firstName: String
  var lastName: String
}

/// Same type, but with the constructor number computed from an explicit TL
/// declaration (the `#d23c81a3` and `;` must be ignored while hashing).
@TLObject(schema: "user#d23c81a3 id:int first_name:string last_name:string = User;")
struct UserFromSchema: Equatable {
  var id: Int32
  var firstName: String
  var lastName: String
}

/// `resPQ#05162463` from the MTProto handshake, with an explicit id.
@TLObject(id: 0x0516_2463)
struct ResPQ: Equatable {
  var nonce: TLInt128
  var serverNonce: TLInt128
  var pq: Data
  var serverPublicKeyFingerprints: [Int64]
}

/// Conditional fields: `flags:#`, a `flags.2?true` presence bit and a
/// `flags.0?int` value.
@TLObject
struct Dialog: Equatable {
  @TLFlags var flags: UInt32 = 0
  @TLConditional(bit: 2) var pinned: Bool = false
  var peerID: Int64
  @TLConditional(bit: 0) var topMessage: Int32?
}

/// Two flags bitfields in one constructor.
@TLObject
struct MultiFlags: Equatable {
  @TLFlags var flags: UInt32 = 0
  @TLFlags var flags2: UInt32 = 0
  @TLConditional("flags", bit: 1) var first: Int32?
  @TLConditional("flags2", bit: 0) var second: String?
}

@TLObject(id: 0x1234_5678)
struct IntBox: Equatable {
  var values: [Int32]
}

@TLObject(id: 0x1234_5678)
struct BareIntBox: Equatable {
  @TLBare var values: [Int32]
}

@TLObject(id: 0x1122_3344)
struct BoxedUserBox: Equatable {
  var user: User
}

@TLObject(id: 0x1122_3344)
struct BareUserBox: Equatable {
  @TLBare var user: User
}

// A bare single-constructor element type, mirroring mtproto's
// `future_salt#0949d9dc valid_since:int valid_until:int salt:long = FutureSalt`.
@TLObject(id: 0x0949_d9dc)
struct Salt: Equatable {
  var validSince: Int32
  var validUntil: Int32
  var salt: Int64
}

// A boxed vector whose *elements* are bare (`@TLBareElements` only): the
// `Vector<%t>` spelling.
@TLObject(id: 0x1111_2222)
struct BoxedVectorBareElements: Equatable {
  @TLBareElements var salts: [Salt]
}

// A boxed vector with the default (boxed) elements, for byte-size comparison.
@TLObject(id: 0x1111_2222)
struct BoxedVectorBoxedElements: Equatable {
  var salts: [Salt]
}

// A fully bare vector of bare elements (`@TLBare @TLBareElements`): the exact
// `future_salts#ae500895 ... salts:vector<future_salt>` shape, whose elements
// once went out boxed — which peers read as endless `bad_server_salt`.
@TLObject(id: 0xae50_0895)
struct FullyBareSalts: Equatable {
  var reqMsgId: Int64
  var now: Int32
  @TLBare @TLBareElements var salts: [Salt]
}

@TLObject
struct Kitchen: Equatable {
  var count: Int64
  var ratio: Double
  var payload: Data
  var names: [String]
  var ok: Bool
  var nested: [User]
  @TLOmit var cached: Int = 99
}

/// An enum: one TL constructor per case, ids derived from case declarations.
@TLObject
enum InputPeer: Equatable {
  case inputPeerEmpty
  case inputPeerUser(userId: Int64, accessHash: Int64)
}

/// An enum with explicit per-case constructor numbers.
@TLObject
enum Storage: Equatable {
  @TLCase(id: 0xaaaa_aaaa) case empty
  @TLCase(schema: "storagePartial bytes:bytes = Storage") case partial(bytes: Data)
}

// MARK: - Primitive wire format

@Suite struct WriterReaderTests {
  @Test func intAndLongLayout() throws {
    var writer = TLWriter()
    writer.writeInt32(1)
    writer.writeInt64(-2)
    #expect(
      writer.data
        == Data([
          0x01, 0x00, 0x00, 0x00,
          0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ]))

    var reader = TLReader(writer.data)
    #expect(try reader.readInt32() == 1)
    #expect(try reader.readInt64() == -2)
    #expect(reader.isAtEnd)
  }

  @Test func shortStringPadding() throws {
    // "test": 1 length byte + 4 bytes + 3 zero-padding bytes = 8 bytes.
    var writer = TLWriter()
    writer.writeString("test")
    #expect(writer.data == Data([0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00]))

    var reader = TLReader(writer.data)
    #expect(try reader.readString() == "test")
    #expect(reader.isAtEnd)
  }

  @Test func emptyStringIsOneWord() throws {
    var writer = TLWriter()
    writer.writeString("")
    #expect(writer.data == Data([0x00, 0x00, 0x00, 0x00]))
  }

  @Test func longBytesUseFourByteHeader() throws {
    let payload = Data((0..<300).map { UInt8($0 % 251) })
    var writer = TLWriter()
    writer.writeBytes(payload)
    // 0xFE + 3-byte length + 300 payload bytes; 304 is already aligned.
    #expect(writer.data.count == 304)
    #expect(writer.data.prefix(4) == Data([0xFE, 0x2C, 0x01, 0x00]))

    var reader = TLReader(writer.data)
    #expect(try reader.readBytes() == payload)
    #expect(reader.isAtEnd)
  }

  @Test func boolConstructors() throws {
    #expect(true.tlSerialized() == Data([0xB5, 0x75, 0x72, 0x99]))
    #expect(false.tlSerialized() == Data([0x37, 0x97, 0x79, 0xBC]))
    #expect(try Bool(tlData: Data([0xB5, 0x75, 0x72, 0x99])) == true)
    #expect(throws: TLError.self) {
      try Bool(tlData: Data([0x00, 0x00, 0x00, 0x00]))
    }
  }

  @Test func doubleRoundTrip() throws {
    let value = 1.5
    var reader = TLReader(value.tlSerialized())
    #expect(try Double(tlFrom: &reader) == 1.5)
  }

  @Test func vectorLayout() throws {
    let values: [Int32] = [2, 3, 4]
    let data = values.tlSerialized()
    // vector#1cb5c415 count elements
    #expect(
      data
        == Data([
          0x15, 0xC4, 0xB5, 0x1C,
          0x03, 0x00, 0x00, 0x00,
          0x02, 0x00, 0x00, 0x00,
          0x03, 0x00, 0x00, 0x00,
          0x04, 0x00, 0x00, 0x00,
        ]))
    #expect(try [Int32](tlData: data) == values)
    // Bare form drops the constructor word.
    #expect(values.tlSerializedBare() == data.dropFirst(4))
  }

  @Test func truncatedInputThrows() throws {
    var reader = TLReader(Data([0x01, 0x02]))
    #expect(throws: TLError.endOfData(needed: 4, remaining: 2)) {
      _ = try reader.readUInt32()
    }
  }
}

// MARK: - CRC32 / TL declarations

@Suite struct SchemaTests {
  @Test func crc32KnownVector() {
    // The canonical CRC-32 check value.
    #expect(TLSchema.crc32(of: "123456789") == 0xCBF4_3926)
  }

  @Test func userConstructorMatchesDocs() {
    // https://core.telegram.org/mtproto/TL: "this value is the CRC32 of
    // the string 'user id:int first_name:string last_name:string = User'"
    #expect(
      TLSchema.constructorID(
        forDeclaration: "user id:int first_name:string last_name:string = User")
        == 0xd23c_81a3
    )
  }

  @Test func normalizationIgnoresIDSemicolonParens() {
    #expect(
      TLSchema.constructorID(
        forDeclaration: "user#d23c81a3 id:int first_name:string last_name:string = User;")
        == 0xd23c_81a3
    )
    #expect(TLSchema.normalize("a#1 (b c)  = D;") == "a b c = D")
  }
}

// MARK: - @TLObject structs

@Suite struct StructMacroTests {
  @Test func autoDerivedConstructorMatchesTelegram() {
    // The macro derives "user id:int first_name:string = User" from the
    // Swift declaration (camelCase → snake_case, Int32 → int, ...).
    #expect(User.tlConstructorID == 0xd23c_81a3)
    #expect(UserFromSchema.tlConstructorID == 0xd23c_81a3)
  }

  @Test func userRoundTripAndLayout() throws {
    let user = User(id: 42, firstName: "Ada", lastName: "L")
    let data = user.tlSerialized()
    // constructor (LE) + int + "Ada" (1+3 bytes, aligned) + "L" (1+1+2 pad)
    #expect(
      data
        == Data([
          0xA3, 0x81, 0x3C, 0xD2,
          0x2A, 0x00, 0x00, 0x00,
          0x03, 0x41, 0x64, 0x61,
          0x01, 0x4C, 0x00, 0x00,
        ]))
    #expect(try User(tlData: data) == user)
  }

  @Test func wrongConstructorThrows() throws {
    var bad = User(id: 1, firstName: "x", lastName: "y").tlSerialized()
    bad[0] ^= 0xFF
    #expect(throws: TLError.self) {
      _ = try User(tlData: bad)
    }
  }

  @Test func explicitIDResPQRoundTrip() throws {
    #expect(ResPQ.tlConstructorID == 0x0516_2463)
    let value = ResPQ(
      nonce: .random(),
      serverNonce: .random(),
      pq: Data([0x17, 0xED, 0x48, 0x94, 0x1A, 0x08, 0xF9, 0x81]),
      serverPublicKeyFingerprints: [-4_344_800_451_088_585_951]
    )
    let data = value.tlSerialized()
    #expect(data.prefix(4) == Data([0x63, 0x24, 0x16, 0x05]))
    #expect(try ResPQ(tlData: data) == value)
  }

  @Test func kitchenSinkRoundTripSkipsOmitted() throws {
    let value = Kitchen(
      count: .max,
      ratio: -0.25,
      payload: Data([1, 2, 3, 4, 5]),
      names: ["a", "bb", "ccc"],
      ok: true,
      nested: [
        User(id: 1, firstName: "x", lastName: "a"), User(id: 2, firstName: "y", lastName: "b"),
      ],
      cached: 7
    )
    let decoded = try Kitchen(tlData: value.tlSerialized())
    #expect(decoded.count == value.count)
    #expect(decoded.ratio == value.ratio)
    #expect(decoded.payload == value.payload)
    #expect(decoded.names == value.names)
    #expect(decoded.ok == value.ok)
    #expect(decoded.nested == value.nested)
    // @TLOmit fields are not serialized; the default value is used.
    #expect(decoded.cached == 99)
  }

  @Test func bareVectorDropsConstructor() throws {
    let boxed = IntBox(values: [1, 2]).tlSerialized()
    let bare = BareIntBox(values: [1, 2]).tlSerialized()
    #expect(boxed.count == bare.count + 4)
    #expect(try BareIntBox(tlData: bare) == BareIntBox(values: [1, 2]))
    // The vector constructor only appears in the boxed form.
    #expect(boxed[4..<8] == Data([0x15, 0xC4, 0xB5, 0x1C]))
    #expect(bare[4..<8] == Data([0x02, 0x00, 0x00, 0x00]))
  }

  @Test func bareNestedObjectDropsConstructor() throws {
    let user = User(id: 9, firstName: "Bob", lastName: "Builder")
    let boxed = BoxedUserBox(user: user).tlSerialized()
    let bare = BareUserBox(user: user).tlSerialized()
    #expect(boxed.count == bare.count + 4)
    #expect(try BareUserBox(tlData: bare) == BareUserBox(user: user))
  }

  // @TLBareElements drops each element's constructor (here `future_salt`'s
  // 0x0949d9dc), but keeps the vector's own 0x1cb5c415 constructor.
  @Test func bareElementsDropPerElementConstructor() throws {
    let salts = [
      Salt(validSince: 1, validUntil: 2, salt: 3),
      Salt(validSince: 4, validUntil: 5, salt: 6),
    ]
    let boxed = BoxedVectorBoxedElements(salts: salts).tlSerialized()
    let bareElems = BoxedVectorBareElements(salts: salts).tlSerialized()
    // Two elements, each shedding its 4-byte constructor.
    #expect(boxed.count == bareElems.count + 8)
    // The vector constructor (0x1cb5c415) survives in both forms.
    #expect(bareElems[4..<8] == Data([0x15, 0xC4, 0xB5, 0x1C]))
    #expect(bareElems[8..<12] == Data([0x02, 0x00, 0x00, 0x00]))  // count
    // First element starts immediately with valid_since (1), not 0x0949d9dc.
    #expect(bareElems[12..<16] == Data([0x01, 0x00, 0x00, 0x00]))
    #expect(try BoxedVectorBareElements(tlData: bareElems) == BoxedVectorBareElements(salts: salts))
  }

  // The `future_salts` regression: a bare vector of bare elements must carry
  // neither the 0x1cb5c415 vector prefix nor any 0x0949d9dc element prefix, so
  // the client recovers each `salt` from the right offset.
  @Test func fullyBareVectorOfBareElements() throws {
    let value = FullyBareSalts(
      reqMsgId: 0x1122_3344_5566_7788, now: 0x0A0B_0C0D,
      salts: [Salt(validSince: 100, validUntil: 200, salt: 0x7766_5544_3322_1100)])
    let data = value.tlSerialized()
    // constructor(4) + req_msg_id(8) + now(4) + count(4) + element(4+4+8).
    #expect(data.count == 4 + 8 + 4 + 4 + 16)
    #expect(data[0..<4] == Data([0x95, 0x08, 0x50, 0xAE]))  // 0xae500895, LE
    #expect(data[16..<20] == Data([0x01, 0x00, 0x00, 0x00]))  // count, no vector ctor
    // The element starts at offset 20 with valid_since=100, NOT 0x0949d9dc.
    #expect(data[20..<24] == Data([0x64, 0x00, 0x00, 0x00]))
    #expect(data[20..<24] != Data([0xDC, 0xD9, 0x49, 0x09]))
    // Round-trips, and `salt` is recovered exactly (the field the bug shifted).
    let decoded = try FullyBareSalts(tlData: data)
    #expect(decoded == value)
    #expect(decoded.salts.first?.salt == 0x7766_5544_3322_1100)
  }
}

// MARK: - Conditional fields (flags)

@Suite struct FlagsTests {
  @Test func flagsBitsComputedFromFields() throws {
    let dialog = Dialog(pinned: true, peerID: 7, topMessage: nil)
    let data = dialog.tlSerialized()
    // constructor + flags + long; the Bool lives in bit 2, nothing extra.
    #expect(data.count == 4 + 4 + 8)
    #expect(data[4..<8] == Data([0x04, 0x00, 0x00, 0x00]))

    let decoded = try Dialog(tlData: data)
    #expect(decoded.pinned == true)
    #expect(decoded.peerID == 7)
    #expect(decoded.topMessage == nil)
    #expect(decoded.flags == 0b100)
  }

  @Test func optionalConditionalSerializedWhenPresent() throws {
    let dialog = Dialog(pinned: false, peerID: -1, topMessage: 123)
    let data = dialog.tlSerialized()
    #expect(data.count == 4 + 4 + 8 + 4)
    #expect(data[4..<8] == Data([0x01, 0x00, 0x00, 0x00]))

    let decoded = try Dialog(tlData: data)
    #expect(decoded.pinned == false)
    #expect(decoded.topMessage == 123)
  }

  @Test func staleStoredFlagsAreRecomputed() throws {
    // The stored bitfield is ignored on encode; bits always reflect the
    // actual fields. It is not an initializer parameter (the synthesized
    // memberwise init hides it), so stale bits have to be stored after the fact.
    var dialog = Dialog(pinned: false, peerID: 0, topMessage: nil)
    dialog.flags = 0xFFFF_FFFF
    let data = dialog.tlSerialized()
    #expect(data[4..<8] == Data([0x00, 0x00, 0x00, 0x00]))
    #expect(try Dialog(tlData: data).flags == 0)
  }

  @Test func multipleFlagsFields() throws {
    let all = MultiFlags(first: 5, second: "hi")
    let none = MultiFlags()
    for value in [all, none] {
      #expect(try MultiFlags(tlData: value.tlSerialized()).first == value.first)
      #expect(try MultiFlags(tlData: value.tlSerialized()).second == value.second)
    }
    let data = all.tlSerialized()
    #expect(data[4..<8] == Data([0x02, 0x00, 0x00, 0x00]))  // flags.1
    #expect(data[8..<12] == Data([0x01, 0x00, 0x00, 0x00]))  // flags2.0
  }
}

// MARK: - @TLObject enums

@Suite struct EnumMacroTests {
  @Test func derivedCaseConstructorsMatchTelegram() {
    // inputPeerEmpty#7f3b18ea = InputPeer; (official schema)
    #expect(InputPeer.inputPeerEmpty.tlConstructorID == 0x7f3b_18ea)
    #expect(
      InputPeer.tlConstructorIDs == [
        TLSchema.constructorID(forDeclaration: "inputPeerEmpty = InputPeer"),
        TLSchema.constructorID(
          forDeclaration: "inputPeerUser user_id:long access_hash:long = InputPeer"),
      ]
    )
  }

  @Test func enumRoundTrip() throws {
    let values: [InputPeer] = [
      .inputPeerEmpty,
      .inputPeerUser(userId: 123_456_789, accessHash: -42),
    ]
    for value in values {
      let data = value.tlSerialized()
      #expect(try InputPeer(tlData: data) == value)
    }
  }

  @Test func explicitCaseIDs() throws {
    #expect(Storage.empty.tlConstructorID == 0xaaaa_aaaa)
    #expect(
      Storage.partial(bytes: Data()).tlConstructorID
        == TLSchema.constructorID(forDeclaration: "storagePartial bytes:bytes = Storage")
    )
    let value = Storage.partial(bytes: Data([9, 9, 9]))
    #expect(try Storage(tlData: value.tlSerialized()) == value)
  }

  @Test func unknownConstructorThrows() throws {
    let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    #expect(throws: TLError.self) {
      _ = try InputPeer(tlData: data)
    }
  }

  @Test func enumsNestInsideVectorsAndObjects() throws {
    let peers: [InputPeer] = [.inputPeerEmpty, .inputPeerUser(userId: 1, accessHash: 2)]
    let data = peers.tlSerialized()
    #expect(try [InputPeer](tlData: data) == peers)
  }
}

// MARK: - Wide integers

@Suite struct WideIntegerTests {
  @Test func int128LittleEndianLayout() throws {
    let value = TLInt128(low: 0x0807_0605_0403_0201, high: 0x100F_0E0D_0C0B_0A09)
    let data = value.tlSerialized()
    #expect(data == Data((1...16).map { UInt8($0) }))
    #expect(try TLInt128(tlData: data) == value)
  }

  @Test func int256RoundTrip() throws {
    let value = TLInt256.random()
    #expect(try TLInt256(tlData: value.tlSerialized()) == value)
    #expect(value.tlSerialized().count == 32)
  }
}
