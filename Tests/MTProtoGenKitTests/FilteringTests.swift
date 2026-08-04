import Testing

@_spi(GeneratorInternals) @testable import MTProtoGenKit

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// A schema carrying vendor entries under a `vendor.*` namespace, one of which
// (`vendor.dummyPeer`) is a constructor of the real `Peer` type and another
// (`vendor.peer`) would claim the Swift name the real `peer` constructor wants.
// Both are the ways a spliced-in namespace can corrupt real declarations.
private let vendoredSchema = """
  {
    "constructors": [
      {"id": "11", "predicate": "peer", "params": [{"name": "id", "type": "long"}], "type": "Peer"},
      {"id": "12", "predicate": "vendor.dummyPeer", "params": [], "type": "Peer"},
      {"id": "13", "predicate": "vendor.peer", "params": [], "type": "vendor.Thing"}
    ],
    "methods": [
      {"id": "100", "method": "auth.sendCode", "params": [
        {"name": "phone", "type": "string"}], "type": "Peer"},
      {"id": "101", "method": "vendor.customMethod", "params": [], "type": "Peer"}
    ]
  }
  """

/// The same schema with the vendor entries never present, which is what the
/// exclusion has to be equivalent to.
private let cleanSchema = """
  {
    "constructors": [
      {"id": "11", "predicate": "peer", "params": [{"name": "id", "type": "long"}], "type": "Peer"}
    ],
    "methods": [
      {"id": "100", "method": "auth.sendCode", "params": [
        {"name": "phone", "type": "string"}], "type": "Peer"}
    ]
  }
  """

@Suite("Namespace exclusion")
struct NamespaceExclusionTests {
  private func generate(_ schema: String, excluding namespaces: Set<String>) throws
    -> [GeneratedFile]
  {
    try MTProtoGenerator(
      options: GeneratorOptions(mode: .types, excludedNamespaces: namespaces)
    ).generate(schemaData: Data(schema.utf8))
  }

  @Test func excludingANamespaceMatchesItNeverHavingBeenThere() throws {
    let filtered = try generate(vendoredSchema, excluding: ["vendor"])
    let clean = try generate(cleanSchema, excluding: [])
    // Byte-identical, not merely "no vendor files": this is the guarantee that
    // lets a schema keep its vendor entries without touching generated output.
    #expect(filtered == clean)
  }

  @Test func excludedEntriesDoNotClaimNamesOrJoinBoxedEnums() throws {
    let files = try generate(vendoredSchema, excluding: ["vendor"])
    let peer = try #require(files.first { $0.path == "Types/Peer.swift" }?.contents)
    // `vendor.dummyPeer` would have made `Peer` a multi-constructor type.
    #expect(!peer.contains("@TLType"))
    #expect(peer.contains("public struct Peer: Equatable, Sendable"))
    // `vendor.peer` would have taken `Peer`, pushing the real one to `Peer_`.
    #expect(!peer.contains("Peer_"))

    let namespaces = try #require(files.first { $0.path == "Support/Namespaces.swift" }?.contents)
    #expect(!namespaces.contains("enum Vendor"))
    #expect(namespaces.contains("public enum Auth {"))
    #expect(!files.contains { $0.path.contains("vendor.") })
  }

  @Test func withoutExclusionTheVendorEntriesAreGenerated() throws {
    let files = try generate(vendoredSchema, excluding: [])
    #expect(files.contains { $0.path == "Methods/vendor.customMethod.swift" })
    let namespaces = try #require(files.first { $0.path == "Support/Namespaces.swift" }?.contents)
    #expect(namespaces.contains("public enum Vendor {"))
  }

  @Test func exclusionOnlyMatchesWholeNamespaces() throws {
    // Not a prefix match: `vendorish.*` and the un-namespaced `vendor` survive.
    let schema = """
      {
        "constructors": [
          {"id": "11", "predicate": "vendor", "params": [], "type": "Vendor"},
          {"id": "12", "predicate": "vendorish.thing", "params": [], "type": "vendorish.Thing"}
        ],
        "methods": []
      }
      """
    let files = try generate(schema, excluding: ["vendor"])
    #expect(files.contains { $0.path == "Types/Vendor.swift" })
    #expect(files.contains { $0.path == "Types/vendorish.Thing.swift" })
  }
}

@Suite("Method manifest")
struct MethodManifestTests {
  @Test func parsesNamesIgnoringCommentsAndBlankLines() throws {
    let manifest = """
      # The methods this build needs.
      auth.sendCode
        messages.sendMessage\t

      users.getUsers  # inline comment
      # A trailing comment-only line.
      """
    #expect(
      try MethodManifest.parse(manifest) == [
        "auth.sendCode", "messages.sendMessage", "users.getUsers",
      ])
  }

  @Test func duplicatesCollapseAndGlobalMethodsAreAllowed() throws {
    #expect(try MethodManifest.parse("ping\nping\ninvokeWithLayer") == ["ping", "invokeWithLayer"])
  }

  @Test func rejectsLinesThatCannotBeMethodNames() throws {
    for bad in ["auth sendCode", "auth.send-Code", "auth.sendCode()", "auth..sendCode", ".sendCode"]
    {
      #expect(throws: GeneratorError.self, "accepted '\(bad)'") {
        _ = try MethodManifest.parse(bad)
      }
    }
  }

  @Test func rejectsAManifestThatSelectsNothing() throws {
    // Silently generating an empty schema is the failure this prevents.
    for empty in ["", "\n\n", "# only a comment\n"] {
      #expect(throws: GeneratorError.self) { _ = try MethodManifest.parse(empty) }
    }
  }

  @Test func reportsTheOffendingLineNumber() throws {
    let manifest = "auth.sendCode\n# fine\nnot a name\n"
    #expect(throws: GeneratorError.invalidMethodManifest(
      line: 3, reason: "'not a name' is not a TL method name")
    ) {
      _ = try MethodManifest.parse(manifest)
    }
  }

  @Test func aManifestSelectsExactlyWhatTheFlagsWould() throws {
    let schema = """
      {
        "constructors": [
          {"id": "11", "predicate": "peer", "params": [{"name": "id", "type": "long"}], "type": "Peer"},
          {"id": "12", "predicate": "thing", "params": [], "type": "Thing"}
        ],
        "methods": [
          {"id": "100", "method": "auth.sendCode", "params": [], "type": "Peer"},
          {"id": "101", "method": "auth.signIn", "params": [], "type": "Thing"}
        ]
      }
      """
    func generate(_ selected: Set<String>) throws -> [GeneratedFile] {
      try MTProtoGenerator(options: GeneratorOptions(mode: .types, selectedMethods: selected))
        .generate(schemaData: Data(schema.utf8))
    }
    let fromManifest = try generate(
      try MethodManifest.parse("# implemented\nauth.sendCode\n"))
    #expect(fromManifest == (try generate(["auth.sendCode"])))
    // The closure still applies: `Thing` goes, `Peer` stays.
    #expect(fromManifest.contains { $0.path == "Types/Peer.swift" })
    #expect(!fromManifest.contains { $0.path == "Types/Thing.swift" })
  }
}
