import Testing

@_spi(GeneratorInternals) @testable import MTProtoGenKit

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A miniature schema exercising every generator feature: multi- and
/// single-constructor types, namespaces, flags + conditionals, keyword
/// field names, vectors, the builtin `Bool`, a name collision between the
/// `updates` constructor and the `updates.*` namespace, plain RPC methods
/// and a generic `invokeWith…` wrapper.
private let miniSchema = """
  {
    "constructors": [
      {"id": "-1132882121", "predicate": "boolFalse", "params": [], "type": "Bool"},
      {"id": "2134579434", "predicate": "inputPeerEmpty", "params": [], "type": "InputPeer"},
      {"id": "1234567", "predicate": "inputPeerUser", "params": [
        {"name": "user_id", "type": "long"},
        {"name": "access_hash", "type": "long"}], "type": "InputPeer"},
      {"id": "-994444869", "predicate": "error", "params": [
        {"name": "code", "type": "int"},
        {"name": "text", "type": "string"}], "type": "Error"},
      {"id": "55", "predicate": "auth.sentCode", "params": [
        {"name": "flags", "type": "#"},
        {"name": "verified", "type": "flags.0?true"},
        {"name": "timeout", "type": "flags.1?int"},
        {"name": "peer", "type": "InputPeer"},
        {"name": "default", "type": "flags.2?string"}], "type": "auth.SentCode"},
      {"id": "56", "predicate": "auth.sentCodeSuccess", "params": [
        {"name": "hints", "type": "Vector<string>"}], "type": "auth.SentCode"},
      {"id": "77", "predicate": "updates", "params": [
        {"name": "seq", "type": "int"}], "type": "Updates"},
      {"id": "78", "predicate": "updatesTooLong", "params": [], "type": "Updates"}
    ],
    "methods": [
      {"id": "100", "method": "auth.sendCode", "params": [
        {"name": "phone_number", "type": "string"},
        {"name": "settings", "type": "Error"}], "type": "auth.SentCode"},
      {"id": "101", "method": "updates.getState", "params": [], "type": "Updates"},
      {"id": "102", "method": "invokeWithLayer", "params": [
        {"name": "layer", "type": "int"},
        {"name": "query", "type": "!X"}], "type": "X"},
      {"id": "103", "method": "users.getUsers", "params": [
        {"name": "id", "type": "Vector<InputPeer>"}], "type": "Vector<Bool>"}
    ]
  }
  """

private func generate(
  mode: GeneratorOptions.Mode = .client,
  visibility: GeneratorOptions.Visibility = .public,
  selectedMethods: Set<String>? = nil
) throws -> [GeneratedFile] {
  let options = GeneratorOptions(
    mode: mode, visibility: visibility, selectedMethods: selectedMethods)
  return try MTProtoGenerator(options: options).generate(schemaData: Data(miniSchema.utf8))
}

private func contents(_ files: [GeneratedFile], _ path: String) throws -> String {
  try #require(files.first { $0.path == path }?.contents, "missing \(path)")
}

@Suite("MTProtoGenerator")
struct GeneratorTests {
  @Test func generationIsDeterministic() throws {
    let first = try generate()
    let second = try generate()
    #expect(first == second)
  }

  @Test func emitsOneFilePerTypeAndMethod() throws {
    let files = try generate()
    let paths = Set(files.map(\.path))
    // Builtin `Bool` is not generated; everything else gets its own file.
    let expected: Set<String> = [
      "Support/Namespaces.swift",
      "Types/InputPeer.swift", "Types/Error.swift", "Types/auth.SentCode.swift",
      "Types/Updates.swift",
      "Methods/auth.sendCode.swift", "Methods/updates.getState.swift",
      "Methods/invokeWithLayer.swift", "Methods/users.getUsers.swift",
      "Client/TLClient.swift", "Client/TLClient+Auth.swift", "Client/TLClient+Methods.swift",
      "Client/TLClient+Updates.swift", "Client/TLClient+Users.swift",
    ]
    #expect(paths == expected)
  }

  @Test func namespacesAreNestedUnderTLRoot() throws {
    let files = try generate()
    let namespaces = try contents(files, "Support/Namespaces.swift")
    #expect(namespaces.contains("public enum TL {"))
    #expect(namespaces.contains("public enum Auth {"))
    #expect(namespaces.contains("public enum Users {"))

    let sentCode = try contents(files, "Types/auth.SentCode.swift")
    #expect(sentCode.contains("extension TL.Auth {"))
    #expect(sentCode.contains("public struct SentCode: Equatable, Sendable"))
  }

  @Test func multiConstructorTypesBecomeTLTypeEnums() throws {
    let files = try generate()
    let inputPeer = try contents(files, "Types/InputPeer.swift")
    #expect(inputPeer.contains("@TLType"))
    #expect(inputPeer.contains("public indirect enum InputPeerType: Equatable, Sendable"))
    #expect(inputPeer.contains("case inputPeerEmpty(TL.InputPeerEmpty)"))
    #expect(inputPeer.contains("case inputPeerUser(TL.InputPeerUser)"))
    #expect(inputPeer.contains("@TLObject(id: 0x7f3b18ea)"))

    // Single-constructor types are just the struct, referenced directly.
    let error = try contents(files, "Types/Error.swift")
    #expect(error.contains("public struct Error: Equatable, Sendable"))
    #expect(!error.contains("@TLType"))
  }

  @Test func flagsConditionalsAndKeywordsAreMapped() throws {
    let files = try generate()
    let sentCode = try contents(files, "Types/auth.SentCode.swift")
    #expect(sentCode.contains("@TLFlags public var flags: UInt32 = 0"))
    #expect(
      sentCode.contains("@TLConditional(\"flags\", bit: 0) public var verified: Bool = false"))
    #expect(sentCode.contains("@TLConditional(\"flags\", bit: 1) public var timeout: Int32? = nil"))
    #expect(
      sentCode.contains("@TLConditional(\"flags\", bit: 2) public var `default`: String? = nil"))
    #expect(sentCode.contains("public var peer: TL.InputPeerType"))
    // The memberwise initializer (which hides the bitfield) comes from
    // `@TLObject` and the flags-ignoring `==` from `@TLFlagsEquatable`, so the
    // generator spells out neither — it just attaches the attribute. Their
    // behaviour is covered by TLCodingTests.
    #expect(sentCode.contains("@TLFlagsEquatable"))
    #expect(!sentCode.contains("public init("))
    #expect(!sentCode.contains("static func =="))
    // A struct with no bitfield keeps the compiler's own memberwise `==`.
    let error = try contents(files, "Types/Error.swift")
    #expect(!error.contains("@TLFlagsEquatable"))
  }

  @Test func collidingConstructorIsRenamed() throws {
    let files = try generate()
    let updates = try contents(files, "Types/Updates.swift")
    // The `updates` constructor struct would collide with the `Updates`
    // namespace enum (from `updates.getState`), so it gets `_` appended;
    // the case name still mirrors the predicate.
    #expect(updates.contains("public struct Updates_: Equatable, Sendable"))
    #expect(updates.contains("case updates(TL.Updates_)"))
  }

  @Test func methodsCarryTheirReturnType() throws {
    let files = try generate()
    let sendCode = try contents(files, "Methods/auth.sendCode.swift")
    #expect(sendCode.contains("@TLObject(id: 0x00000064, returning: TL.Auth.SentCodeType.self)"))
    #expect(sendCode.contains("public struct SendCode: Equatable, Sendable"))
    #expect(sendCode.contains("public var settings: TL.Error"))

    let getUsers = try contents(files, "Methods/users.getUsers.swift")
    #expect(getUsers.contains("returning: [Bool].self"))

    let wrapper = try contents(files, "Methods/invokeWithLayer.swift")
    #expect(wrapper.contains("public struct InvokeWithLayer<Query: TLFunction>: TLFunction, Sendable"))
    #expect(wrapper.contains("public typealias ReturnType = Query.ReturnType"))
    #expect(wrapper.contains("@TLObject(id: 0x00000066)"))
    #expect(!wrapper.contains("returning:"))
  }

  @Test func clientExposesNamespacedAsyncMethods() throws {
    let files = try generate(mode: .client)
    let core = try contents(files, "Client/TLClient.swift")
    #expect(core.contains("public protocol TLClientTransport: Sendable"))
    #expect(core.contains("public final class TLClient: Sendable"))
    #expect(
      core.contains(
        "public func invoke<Function: TLFunction>(_ function: Function) async throws -> Function.ReturnType"
      ))

    let auth = try contents(files, "Client/TLClient+Auth.swift")
    #expect(auth.contains("public var auth: AuthMethods {"))
    #expect(auth.contains("AuthMethods(client: self)"))
    #expect(
      auth.contains(
        "public func sendCode(phoneNumber: String, settings: TL.Error) async throws -> TL.Auth.SentCodeType"
      ))
    #expect(auth.contains("try await client.invoke(TL.Auth.SendCode(phoneNumber: phoneNumber, settings: settings))"))

    // Generic wrappers go directly onto the client.
    let global = try contents(files, "Client/TLClient+Methods.swift")
    #expect(
      global.contains(
        "public func invokeWithLayer<Query: TLFunction>(layer: Int32, query: Query) async throws -> Query.ReturnType"
      ))
  }

  @Test func visibilityIsApplied() throws {
    let files = try generate(mode: .client, visibility: .internal)
    let inputPeer = try contents(files, "Types/InputPeer.swift")
    #expect(inputPeer.contains("internal struct InputPeerEmpty: Equatable, Sendable"))
    #expect(inputPeer.contains("internal indirect enum InputPeerType"))
    let core = try contents(files, "Client/TLClient.swift")
    #expect(core.contains("internal final class TLClient: Sendable"))
  }

  @Test func selectedMethodsRestrictGenerationToTheirClosure() throws {
    let files = try generate(selectedMethods: ["auth.sendCode"])
    let paths = Set(files.map(\.path))
    // `Error` is reachable as a method parameter; `InputPeer` only
    // transitively, through `auth.sentCode`'s `peer` field. Everything
    // touching only the unselected methods (`Updates`, the generic wrapper,
    // the `updates`/`users` namespaces) disappears.
    let expected: Set<String> = [
      "Support/Namespaces.swift",
      "Types/InputPeer.swift", "Types/Error.swift", "Types/auth.SentCode.swift",
      "Methods/auth.sendCode.swift",
      "Client/TLClient.swift", "Client/TLClient+Auth.swift",
    ]
    #expect(paths == expected)

    let namespaces = try contents(files, "Support/Namespaces.swift")
    #expect(namespaces.contains("public enum Auth {"))
    #expect(!namespaces.contains("enum Updates {"))
    #expect(!namespaces.contains("enum Users {"))

    // The client exposes only the selected namespace's methods.
    let client = try contents(files, "Client/TLClient+Auth.swift")
    #expect(client.contains("public func sendCode("))
  }

  @Test func selectionKeepsFullSchemaNames() throws {
    // Even though `auth.*` is filtered out, the `updates` constructor keeps
    // the `Updates_` rename it gets in a full generation (colliding with the
    // `Updates` namespace enum) — selection must never reshuffle names.
    let files = try generate(selectedMethods: ["updates.getState"])
    let updates = try contents(files, "Types/Updates.swift")
    #expect(updates.contains("public struct Updates_: Equatable, Sendable"))
    #expect(updates.contains("case updates(TL.Updates_)"))
  }

  @Test func unknownSelectedMethodIsRejected() {
    #expect(throws: GeneratorError.unknownSelectedMethod(name: "auth.nope")) {
      _ = try generate(selectedMethods: ["auth.sendCode", "auth.nope"])
    }
  }

  @Test func invalidSchemaIsRejected() {
    #expect(throws: GeneratorError.self) {
      _ = try MTProtoGenerator(options: GeneratorOptions(mode: .client))
        .generate(schemaData: Data("not json".utf8))
    }

    let badID = miniSchema.replacing("\"id\": \"55\"", with: "\"id\": \"zzz\"")
    #expect(throws: GeneratorError.self) {
      _ = try MTProtoGenerator(options: GeneratorOptions(mode: .client))
        .generate(schemaData: Data(badID.utf8))
    }

    // A field referencing a type with no constructors.
    let unknownType = miniSchema.replacing(
      "{\"name\": \"peer\", \"type\": \"InputPeer\"}",
      with: "{\"name\": \"peer\", \"type\": \"MissingType\"}")
    #expect(throws: GeneratorError.self) {
      _ = try MTProtoGenerator(options: GeneratorOptions(mode: .client))
        .generate(schemaData: Data(unknownType.utf8))
    }
  }

  // Regression: a `vector<future_salt>` (lowercase vector of a bare constructor
  // element) must emit both `@TLBare` (bare vector) and `@TLBareElements` (bare
  // elements) — the combination that, when missing, caused endless
  // `bad_server_salt` churn. A boxed `Vector<long>` in the same type must stay
  // plain (no bare attributes).
  @Test func bareVectorOfBareElementsCarriesBothAttributes() throws {
    let schema = """
      {
        "constructors": [
          {"id": "155834844", "predicate": "future_salt", "params": [
            {"name": "valid_since", "type": "int"},
            {"name": "valid_until", "type": "int"},
            {"name": "salt", "type": "long"}], "type": "FutureSalt"},
          {"id": "-1370486635", "predicate": "future_salts", "params": [
            {"name": "req_msg_id", "type": "long"},
            {"name": "now", "type": "int"},
            {"name": "ids", "type": "Vector<long>"},
            {"name": "salts", "type": "vector<future_salt>"}], "type": "FutureSalts"}
        ],
        "methods": []
      }
      """
    let files = try MTProtoGenerator(options: GeneratorOptions(mode: .types))
      .generate(schemaData: Data(schema.utf8))
    let futureSalts = try contents(files, "Types/FutureSalts.swift")
    #expect(futureSalts.contains("@TLBare @TLBareElements public var salts: [TL.FutureSalt]"))
    // The boxed primitive vector keeps the default (boxed) encoding.
    #expect(futureSalts.contains("public var ids: [Int64]"))
    #expect(!futureSalts.contains("@TLBareElements public var ids"))
    #expect(!futureSalts.contains("@TLBare public var ids"))
  }
}
