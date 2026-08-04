import Testing

@_spi(GeneratorInternals) @testable import MTProtoGenKit

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// A schema with a global, an `auth` and a `users` namespace, so a split run
// produces every kind of module: namespaces, types, per-namespace methods, the
// client core and its per-namespace extensions.
private let latestSchema = """
  {
    "constructors": [
      {"id": "11", "predicate": "peer", "params": [{"name": "id", "type": "long"}], "type": "Peer"},
      {"id": "22", "predicate": "auth.sentCode", "params": [
        {"name": "peer", "type": "Peer"}], "type": "auth.SentCode"},
      {"id": "31", "predicate": "foo", "params": [{"name": "x", "type": "int"}], "type": "Foo"},
      {"id": "32", "predicate": "fooEmpty", "params": [], "type": "Foo"}
    ],
    "methods": [
      {"id": "100", "method": "auth.sendCode", "params": [
        {"name": "phone", "type": "string"}], "type": "auth.SentCode"},
      {"id": "200", "method": "auth.signIn", "params": [
        {"name": "code", "type": "string"}], "type": "auth.SentCode"},
      {"id": "300", "method": "users.getFoo", "params": [
        {"name": "peer", "type": "Peer"}], "type": "Foo"},
      {"id": "400", "method": "getPeer", "params": [], "type": "Peer"}
    ]
  }
  """

private func options(
  umbrella: String?, mode: GeneratorOptions.Mode = .client
) -> GeneratorOptions {
  GeneratorOptions(
    mode: mode, visibility: .public, rootNamespaceModule: "MTProtoBaseSchema",
    umbrellaModule: umbrella)
}

private func generatePackage(
  mode: GeneratorOptions.Mode = .client
) throws -> GeneratedPackage {
  try MTProtoGenerator(options: options(umbrella: "Schema", mode: mode))
    .generatePackage(schemaData: Data(latestSchema.utf8))
}

private func generateFlat(mode: GeneratorOptions.Mode = .client) throws -> [GeneratedFile] {
  try MTProtoGenerator(options: options(umbrella: nil, mode: mode))
    .generate(schemaData: Data(latestSchema.utf8))
}

/// The file name of a generated path, without its module subdirectory.
private func basename(_ path: String) -> String {
  String(path.split(separator: "/").last ?? "")
}

/// The `import`ed module names in a generated file, `@_exported` ones included.
private func imports(of file: GeneratedFile) -> Set<String> {
  Set(
    file.contents.split(separator: "\n").compactMap { line in
      let line = line.drop(while: \.isWhitespace)
      for prefix in ["@_exported import ", "import "] where line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count))
      }
      return nil
    })
}

/// Every module name declared in `file`, as `TL.Auth.SentCode` would be
/// referenced: the enclosing `extension TL…` scope plus the member's name.
private func declarations(in file: GeneratedFile) -> Set<String> {
  var scope = ""
  var names: Set<String> = []
  for line in file.contents.split(separator: "\n") {
    if line.hasPrefix("extension ") {
      scope = String(line.dropFirst("extension ".count).split(separator: " ").first ?? "")
      continue
    }
    // Members of a `TL…` extension, plus the top-level protocols and
    // typealiases (`TLClientTransport`) referred to by name.
    for keyword in ["struct ", "enum ", "protocol ", "typealias "] {
      guard let range = line.firstRange(of: "public \(keyword)") else { continue }
      let rest = line[range.upperBound...]
      let name = String(
        rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
      guard !name.isEmpty else { continue }
      names.insert(line.hasPrefix("  ") && !scope.isEmpty ? "\(scope).\(name)" : name)
    }
  }
  return names
}

/// The `TL.…` and `TL…` names `file` refers to, ignoring comments.
private func references(in file: GeneratedFile) -> Set<String> {
  var names: Set<String> = []
  for line in file.contents.split(separator: "\n") {
    let trimmed = line.drop(while: \.isWhitespace)
    guard !trimmed.hasPrefix("//") else { continue }
    var rest = Substring(line)
    while let start = rest.firstRange(of: "TL") {
      let identifier = rest[start.lowerBound...].prefix {
        $0.isLetter || $0.isNumber || $0 == "_" || $0 == "."
      }
      // `TL.Auth.SentCode` names a member; `TLAuthService` a top-level one.
      let components = identifier.split(separator: ".")
      if components.count >= 2 {
        names.insert(components.prefix(3).joined(separator: "."))
        names.insert(components.prefix(2).joined(separator: "."))
      } else {
        names.insert(String(identifier))
      }
      rest = rest[start.upperBound...]
    }
  }
  return names
}

@Suite("Module split")
struct ModuleSplitTests {
  @Test func splitEmitsTheSameSourcesPlusAnUmbrella() throws {
    let package = try generatePackage()
    let flat = try generateFlat()

    // Same files, module directory prefixes aside: the split changes where a
    // declaration is compiled, never what is generated.
    let split = package.modules
      .filter { $0.name != package.umbrella }
      .flatMap { module in module.files.map { basename($0.path) } }
    #expect(Set(split) == Set(flat.map { basename($0.path) }))
    #expect(split.count == flat.count)

    let umbrella = try #require(package.modules.last)
    #expect(umbrella.name == "Schema")
    #expect(umbrella.files.map(\.path) == ["Schema.swift"])
  }

  @Test func generationIsDeterministic() throws {
    #expect(try generatePackage() == (try generatePackage()))
  }

  @Test func modulesCoverTheExpectedGroups() throws {
    let package = try generatePackage()
    #expect(
      package.modules.map(\.name) == [
        "SchemaSupport", "SchemaTypes", "SchemaMethodsGlobal", "SchemaMethodsAuth",
        "SchemaMethodsUsers", "SchemaClient", "SchemaClientGlobal", "SchemaClientAuth",
        "SchemaClientUsers", "Schema",
      ])
    // Directory names are the module names minus the umbrella prefix, so the
    // umbrella's own directory does not collide with a submodule's.
    #expect(Set(package.modules.map(\.directory)).count == package.modules.count)
  }

  @Test func dependenciesFormADAGInDeclarationOrder() throws {
    let package = try generatePackage()
    var seen: Set<String> = []
    for module in package.modules {
      for dependency in module.dependencies {
        #expect(seen.contains(dependency), "\(module.name) depends on later \(dependency)")
      }
      seen.insert(module.name)
    }
  }

  @Test func everyFileImportsOnlyItsModulesDependencies() throws {
    let package = try generatePackage()
    for module in package.modules {
      let allowed = Set(module.dependencies + module.externalDependencies)
        .union(["Foundation", "FoundationEssentials"])
      for file in module.files {
        let unexpected = imports(of: file).subtracting(allowed)
        #expect(unexpected.isEmpty, "\(module.name)/\(file.path) imports \(unexpected)")
      }
    }
  }

  @Test func everyReferenceResolvesThroughTheDependencyGraph() throws {
    let package = try generatePackage()
    var declaringModule: [String: String] = [:]
    for module in package.modules {
      for file in module.files {
        for name in declarations(in: file) { declaringModule[name] = module.name }
      }
    }
    let byName = Dictionary(uniqueKeysWithValues: package.modules.map { ($0.name, $0) })
    /// A module and everything it can see, following declared dependencies.
    func visible(from name: String) -> Set<String> {
      var result: Set<String> = [name]
      var worklist = byName[name]?.dependencies ?? []
      while let next = worklist.popLast() {
        guard result.insert(next).inserted else { continue }
        worklist += byName[next]?.dependencies ?? []
      }
      return result
    }

    for module in package.modules {
      let reachable = visible(from: module.name)
      for file in module.files {
        for name in references(in: file) {
          // Names the runtime declares (`TLReader`) or the root module does
          // (`TL` itself, the base schema's types) are not in the table.
          guard let owner = declaringModule[name] else { continue }
          #expect(
            reachable.contains(owner),
            "\(module.name)/\(file.path) refers to \(name) from \(owner), which it cannot import")
        }
      }
    }
  }

  @Test func umbrellaReexportsEveryModule() throws {
    let package = try generatePackage()
    let umbrella = try #require(package.modules.last)
    let reexported = imports(of: umbrella.files[0])
    for module in package.modules.dropLast() {
      #expect(reexported.contains(module.name))
    }
    // Plus the runtime and the module owning the root `TL` namespace, so a
    // consumer of the umbrella needs no other import.
    #expect(reexported.isSuperset(of: ["TLCoding", "MTProtoBaseSchema"]))
  }

  @Test func manifestDescribesEveryModule() throws {
    let package = try generatePackage()
    struct Manifest: Decodable {
      struct Module: Decodable {
        var name: String
        var directory: String
        var dependencies: [String]
        var externalDependencies: [String]
      }
      var umbrella: String
      var modules: [Module]
    }
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(try package.manifestJSON().utf8))
    #expect(manifest.umbrella == package.umbrella)
    #expect(manifest.modules.map(\.name) == package.modules.map(\.name))
    #expect(manifest.modules.map(\.directory) == package.modules.map(\.directory))
    #expect(manifest.modules.map(\.dependencies) == package.modules.map(\.dependencies))
    #expect(
      manifest.modules.allSatisfy { $0.externalDependencies == ["TLCoding", "MTProtoBaseSchema"] })
  }

  @Test func methodModulesAreIsolatedFromEachOther() throws {
    let package = try generatePackage()
    // A namespace's request structs need only the shared types, so adding an
    // RPC to `auth` never rebuilds `users`.
    for namespace in ["Global", "Auth", "Users"] {
      let module = try #require(package.modules.first { $0.name == "SchemaMethods\(namespace)" })
      #expect(module.dependencies == ["SchemaSupport", "SchemaTypes"])
    }
  }

  @Test func clientModeSplitsPerNamespaceToo() throws {
    let package = try generatePackage(mode: .client)
    #expect(package.modules.map(\.name).contains("SchemaClient"))
    let namespaceClient = try #require(package.modules.first { $0.name == "SchemaClientAuth" })
    // The per-namespace RPC methods extend the `TLClient` object in SchemaClient.
    #expect(namespaceClient.dependencies.contains("SchemaClient"))

    var declaringModule: [String: String] = [:]
    for module in package.modules {
      for file in module.files {
        for name in declarations(in: file) { declaringModule[name] = module.name }
      }
    }
    for module in package.modules {
      let visible = Set(module.dependencies + [module.name])
      for file in module.files {
        for name in references(in: file) {
          guard let owner = declaringModule[name] else { continue }
          #expect(visible.contains(owner), "\(module.name)/\(file.path) cannot see \(name)")
        }
      }
    }
  }

  @Test func typesOnlyRunSplitsWithoutAClient() throws {
    let package = try generatePackage(mode: .types)
    #expect(!package.modules.contains { $0.name.hasPrefix("SchemaClient") })
    #expect(package.modules.last?.name == "Schema")
  }

  @Test func packageGenerationRequiresAnUmbrellaName() throws {
    let generator = MTProtoGenerator(options: options(umbrella: nil))
    #expect(throws: GeneratorError.missingUmbrellaModule) {
      try generator.generatePackage(schemaData: Data(latestSchema.utf8))
    }
  }
}
