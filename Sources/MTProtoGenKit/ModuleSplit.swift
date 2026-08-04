#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One Swift module of a split generation run.
public struct GeneratedModule: Equatable, Sendable {
  /// The module name, e.g. `MyTelegramSchemaTypes`.
  public var name: String
  /// The directory the module's sources go in, relative to the output
  /// directory (and unique across the run).
  public var directory: String
  /// The other generated modules this one imports, in dependency order.
  public var dependencies: [String]
  /// The modules from outside this run this one imports: the `TLCoding`
  /// runtime and, when the root `TL` namespace lives elsewhere, that module.
  public var externalDependencies: [String]
  /// The module's sources, addressed relative to ``directory``.
  public var files: [GeneratedFile]
}

/// A schema generated as several modules re-exported by one umbrella module.
/// See <doc:SplittingIntoModules>.
public struct GeneratedPackage: Equatable, Sendable {
  /// The umbrella module's name — the one consumers import.
  public var umbrella: String
  /// Every module, in dependency order; the umbrella comes last.
  public var modules: [GeneratedModule]

  /// The file name of ``manifestJSON()`` in the output directory.
  public static let manifestFileName = "modules.json"

  /// The module graph as JSON, for build systems to declare targets from:
  /// `{"umbrella": …, "modules": [{"name": …, "directory": …,
  /// "dependencies": […], "externalDependencies": […]}]}`.
  public func manifestJSON() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifest = Manifest(
      umbrella: umbrella,
      modules: modules.map {
        Manifest.Module(
          name: $0.name, directory: $0.directory, dependencies: $0.dependencies,
          externalDependencies: $0.externalDependencies)
      })
    let data = try encoder.encode(manifest)
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  /// The manifest's on-disk shape (the sources themselves are written as files).
  private struct Manifest: Encodable {
    struct Module: Encodable {
      var name: String
      var directory: String
      var dependencies: [String]
      var externalDependencies: [String]
    }
    var umbrella: String
    var modules: [Module]
  }
}

/// The groups a generation run's files fall into. Each becomes one module in a
/// split run; in a single-module run the grouping is just a tag. See
/// <doc:SplittingIntoModules>.
@_spi(GeneratorInternals) public enum ModuleGroup: Hashable, Sendable {
  /// The root `TL` namespace (or its re-export), the namespace enums, and any
  /// shared support declarations. Everything else imports this.
  case support
  /// The latest layer's type declarations, as one module: the TL type graph is
  /// too interconnected to split further.
  case types
  /// The `TLClient` object the per-namespace RPC extensions hang off.
  case clientCore
  /// One TL namespace's client RPC methods.
  case client(namespace: String)
  /// One TL namespace's request structs.
  case methods(namespace: String)
  /// One older layer's `TL.L<N>` declarations.
  case compat(layer: Int)
  /// One older layer's converters onto the latest layer — separate from
  /// ``compat(layer:)`` because these reference the latest layer's *methods*,
  /// which change more often than its types.
  case compatConvert(layer: Int)
  /// A module an additional emitter adds, named by its suffix; it may reference
  /// every other module. See <doc:ExtendingEmission>.
  case aggregate(suffix: String)

  /// The module name's suffix, appended to the umbrella name.
  var nameSuffix: String {
    switch self {
    case .support: return "Support"
    case .types: return "Types"
    case .clientCore: return "Client"
    case .client(let namespace): return "Client\(Self.group(namespace))"
    case .methods(let namespace): return "Methods\(Self.group(namespace))"
    case .compat(let layer): return "CompatL\(layer)"
    case .compatConvert(let layer): return "CompatL\(layer)Convert"
    case .aggregate(let suffix): return suffix
    }
  }

  /// Path prefixes stripped from this group's files, so a module's directory
  /// name is not repeated inside it (`Types/Message.swift` in the `Types`
  /// module becomes `Message.swift`).
  var strippedPathPrefixes: [String] {
    switch self {
    case .support: return ["Support/"]
    case .types: return ["Types/"]
    case .clientCore, .client: return ["Client/"]
    case .methods: return ["Methods/"]
    case .compat(let layer), .compatConvert(let layer): return ["Compat/L\(layer)/"]
    case .aggregate(let suffix): return ["\(suffix)/"]
    }
  }

  /// `auth` → `Auth`, the global namespace → `Global`.
  private static func group(_ namespace: String) -> String {
    namespace.isEmpty ? "Global" : Naming.capitalizedFirst(Naming.camelCase(namespace))
  }
}

/// The module layout of a split run: which module each ``ModuleGroup`` becomes
/// and what it imports.
///
/// Dependencies are declared per group rather than discovered per file, so a
/// module's import list changes only when the module set does.
@_spi(GeneratorInternals) public struct ModuleSplitPlan: Sendable {
  let umbrella: String
  /// Modules from outside this run every generated file may need.
  let externalDependencies: [String]
  /// The groups this run emits, in dependency order.
  let groups: [ModuleGroup]
  /// Method namespaces per compat layer, for the converters' dependencies.
  private let compatMethodNamespaces: [Int: [String]]
  /// Path prefixes an additional emitter's files carry, stripped alongside the
  /// built-in ones.
  private let extraStrippedPathPrefixes: [String]
  private let present: Set<ModuleGroup>

  /// `aggregate` names a trailing module that may reference every other one, for
  /// an additional emitter; `extraStrippedPathPrefixes` are that emitter's own
  /// path prefixes, stripped wherever its files land.
  @_spi(GeneratorInternals) public init(
    umbrella: String, rootNamespaceModule: String?, methodNamespaces: [String],
    clientNamespaces: [String], compatLayers: [Int] = [],
    compatMethodNamespaces: [Int: [String]] = [:], aggregate: String? = nil,
    extraStrippedPathPrefixes: [String] = []
  ) {
    self.umbrella = umbrella
    self.externalDependencies = ["TLCoding"] + (rootNamespaceModule.map { [$0] } ?? [])
    self.compatMethodNamespaces = compatMethodNamespaces
    self.extraStrippedPathPrefixes = extraStrippedPathPrefixes
    var groups: [ModuleGroup] = [.support, .types]
    groups += methodNamespaces.map { .methods(namespace: $0) }
    // After the method modules: a namespace's client extension takes that
    // namespace's request structs, so `groups` stays in dependency order.
    if !clientNamespaces.isEmpty {
      groups.append(.clientCore)
      groups += clientNamespaces.map { .client(namespace: $0) }
    }
    for layer in compatLayers.sorted() {
      groups += [.compat(layer: layer), .compatConvert(layer: layer)]
    }
    if let aggregate { groups.append(.aggregate(suffix: aggregate)) }
    self.groups = groups
    self.present = Set(groups)
  }

  func moduleName(for group: ModuleGroup) -> String { umbrella + group.nameSuffix }

  /// The path prefixes stripped from `group`'s files.
  func strippedPathPrefixes(for group: ModuleGroup) -> [String] {
    group.strippedPathPrefixes + extraStrippedPathPrefixes
  }

  /// The generated modules `group` depends on, in dependency order.
  func dependencies(for group: ModuleGroup) -> [ModuleGroup] {
    switch group {
    case .support:
      return []
    case .types:
      return [.support]
    case .clientCore:
      return [.support, .types]
    case .client(let namespace):
      // The RPC methods extend the `TLClient` object with calls that take the
      // namespace's request structs.
      return [.support, .types, .clientCore]
        + [ModuleGroup.methods(namespace: namespace)].filter(present.contains)
    case .methods:
      return [.support, .types]
    case .compat:
      return [.support, .types]
    case .compatConvert(let layer):
      // The converters map an older layer's requests onto the latest ones, so
      // only the namespaces that layer routes are needed.
      let namespaces = (compatMethodNamespaces[layer] ?? [])
        .map { ModuleGroup.methods(namespace: $0) }
        .filter(present.contains)
      return [.support, .types, .compat(layer: layer)] + namespaces
    case .aggregate:
      return groups.filter { $0 != group }
    }
  }

  /// The modules every file of `group` imports: its dependencies plus the
  /// external ones (`TLCoding` is always written by ``SwiftFile``).
  @_spi(GeneratorInternals) public func imports(for group: ModuleGroup) -> [String] {
    dependencies(for: group).map(moduleName(for:))
      + externalDependencies.filter { $0 != "TLCoding" }
  }

  /// The umbrella module's single source: it re-exports every other module, so
  /// `import <umbrella>` still presents the whole `TL.*` surface.
  func umbrellaModule() -> GeneratedModule {
    let reexports = (externalDependencies + groups.map(moduleName(for:)))
      .map { "@_exported import \($0)" }
      .joined(separator: "\n")
    return GeneratedModule(
      name: umbrella,
      directory: "Umbrella",
      dependencies: groups.map(moduleName(for:)),
      externalDependencies: externalDependencies,
      files: [
        GeneratedFile(
          path: "\(umbrella).swift",
          contents: """
            \(SwiftFile.header)
            // The schema is generated as several modules so that a change to one of
            // them does not rebuild the rest; this umbrella re-exports all of them,
            // so `import \(umbrella)` presents the whole `TL.*` surface as one module.
            \(reexports)

            """)
      ])
  }
}
