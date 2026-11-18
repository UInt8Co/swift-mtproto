import Testing

@_spi(GeneratorInternals) @testable import MTProtoGenKit

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A schema of `constructors` alone: `(predicate, params, type)` with
/// params as `"name:type"`; ids are assigned in order.
private func schema(_ constructors: [(String, [String], String)]) -> Data {
  let entries = constructors.enumerated().map { offset, constructor in
    let (predicate, params, type) = constructor
    let paramList = params.map { param in
      let parts = param.split(separator: ":", maxSplits: 1)
      return "{\"name\": \"\(parts[0])\", \"type\": \"\(parts[1])\"}"
    }.joined(separator: ", ")
    return
      "{\"id\": \"\(offset + 1)\", \"predicate\": \"\(predicate)\", \"params\": [\(paramList)], \"type\": \"\(type)\"}"
  }
  return Data("{\"constructors\": [\(entries.joined(separator: ", "))], \"methods\": []}".utf8)
}

/// The generated enum declarations, keyed by enum name, as the lines
/// `enum X` and `[indirect ]case y(…)` they are made of.
private func enums(_ constructors: [(String, [String], String)]) throws -> [String: [String]] {
  let files = try MTProtoGenerator(options: GeneratorOptions(mode: .types))
    .generate(schemaData: schema(constructors))
  var result: [String: [String]] = [:]
  for file in files {
    var current: String?
    for line in file.contents.split(separator: "\n") {
      let text = String(line.drop { $0 == " " })
      if let match = text.firstMatch(of: /^public (indirect )?enum (\w+): Equatable/) {
        current = String(match.2)
        result[current!] = [text]
      } else if let current, text.hasPrefix("case ") || text.hasPrefix("indirect case ") {
        result[current]!.append(String(text.prefix { $0 != "(" }))
      } else if text == "}" {
        current = nil
      }
    }
  }
  return result
}

/// The `indirect` cases of each enum, as `Enum.case`.
private func indirectCases(_ constructors: [(String, [String], String)]) throws -> Set<String> {
  var result: Set<String> = []
  for (name, lines) in try enums(constructors) {
    #expect(!lines[0].contains("indirect enum"), "\(name) is indirect as a whole")
    for line in lines.dropFirst() where line.hasPrefix("indirect case ") {
      result.insert("\(name).\(line.dropFirst("indirect case ".count))")
    }
  }
  return result
}

@Suite("Indirect cases")
struct IndirectCasesTests {
  @Test func nonRecursiveEnumHasNoIndirect() throws {
    let generated = try enums([
      ("inputPeerEmpty", [], "InputPeer"),
      ("inputPeerUser", ["user_id:long", "access_hash:long"], "InputPeer"),
      ("inputPeerWrapped", ["inner:Wrapped"], "InputPeer"),
      ("wrapped", ["id:int"], "Wrapped"),
    ])
    #expect(
      generated["InputPeerType"] == [
        "public enum InputPeerType: Equatable, Sendable {",
        "case inputPeerEmpty", "case inputPeerUser", "case inputPeerWrapped",
      ])
  }

  @Test func selfRecursionMarksOnlyTheRecursiveCase() throws {
    #expect(
      try indirectCases([
        ("nodeLeaf", ["value:int"], "Node"),
        ("nodeBranch", ["left:Node", "right:Node"], "Node"),
        // Holds the recursive type without being part of its cycle.
        ("holderEmpty", [], "Holder"),
        ("holderNode", ["node:Node"], "Holder"),
      ]) == ["NodeType.nodeBranch"])
  }

  @Test func mutualRecursionAcrossTwoTypes() throws {
    #expect(
      try indirectCases([
        ("aEmpty", [], "A"),
        ("aWithB", ["b:B"], "A"),
        ("bEmpty", [], "B"),
        ("bWithA", ["a:A"], "B"),
      ]) == ["AType.aWithB", "BType.bWithA"])
  }

  @Test func mutualRecursionAcrossThreeTypes() throws {
    #expect(
      try indirectCases([
        ("aEmpty", [], "A"),
        ("aWithB", ["b:B"], "A"),
        ("bEmpty", [], "B"),
        ("bWithC", ["c:C"], "B"),
        ("bWithInt", ["x:int"], "B"),
        ("cEmpty", [], "C"),
        ("cWithA", ["a:A"], "C"),
      ]) == ["AType.aWithB", "BType.bWithC", "CType.cWithA"])
  }

  @Test func recursionOnlyThroughVectorNeedsNoIndirect() throws {
    #expect(
      try indirectCases([
        ("treeLeaf", [], "Tree"),
        ("treeNode", ["children:Vector<Tree>"], "Tree"),
        ("treeOptionalChildren", ["flags:#", "children:flags.0?Vector<Tree>"], "Tree"),
        // A vector of a struct that leads back is heap-backed as well.
        ("treeForest", ["forest:Vector<Forest>"], "Tree"),
        ("forest", ["root:Tree"], "Forest"),
      ]).isEmpty)
  }

  @Test func recursionThroughAFlagField() throws {
    #expect(
      try indirectCases([
        ("messageEmpty", ["id:int"], "Message"),
        ("message", ["flags:#", "pinned:flags.0?true", "reply_to:flags.1?Message"], "Message"),
      ]) == ["MessageType.message"])
  }

  @Test func recursionThroughAPayloadStruct() throws {
    #expect(
      try indirectCases([
        ("blockText", ["text:string"], "Block"),
        ("blockQuote", ["quote:Quote"], "Block"),
        ("blockList", ["items:Vector<Block>"], "Block"),
        // Single-constructor types are bare structs in the chain.
        ("quote", ["flags:#", "caption:flags.0?Caption", "author:string"], "Quote"),
        ("caption", ["inner:Block"], "Caption"),
      ]) == ["BlockType.blockQuote"])
  }

  @Test func recursionThroughABareConstructorReference() throws {
    // `%pair` names the constructor rather than its boxed type.
    #expect(
      try indirectCases([
        ("listNil", [], "List"),
        ("listCons", ["head:int", "tail:%pair"], "List"),
        ("pair", ["next:List"], "Pair"),
      ]) == ["ListType.listCons"])
  }

  @Test func analysisIsDeterministic() throws {
    let constructors: [(String, [String], String)] = [
      ("aEmpty", [], "A"), ("aWithB", ["b:B"], "A"),
      ("bEmpty", [], "B"), ("bWithA", ["a:A"], "B"), ("bWithSelf", ["b:B"], "B"),
    ]
    let first = try MTProtoGenerator(options: GeneratorOptions(mode: .types))
      .generate(schemaData: schema(constructors))
    for _ in 0..<5 {
      let again = try MTProtoGenerator(options: GeneratorOptions(mode: .types))
        .generate(schemaData: schema(constructors))
      #expect(again == first)
    }
    #expect(try indirectCases(constructors) == ["AType.aWithB", "BType.bWithA", "BType.bWithSelf"])
  }

  @Test func stronglyConnectedComponentsGroupMutuallyReachableNodes() {
    // 0 → 1 → 2 → 0, 2 → 3, 3 → 3, 4 alone.
    let component = ResolvedSchema.stronglyConnectedComponents(edges: [[1], [2], [0, 3], [3], []])
    #expect(component[0] == component[1] && component[1] == component[2])
    #expect(component[3] != component[0])
    #expect(component[4] != component[0] && component[4] != component[3])
  }
}
