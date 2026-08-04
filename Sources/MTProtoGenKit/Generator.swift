import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One emitted file together with the module group it belongs to.
///
/// Emission and layout are separate steps: a run emits `EmittedFile`s, then
/// ``MTProtoGenerator/assemble(_:)`` or
/// ``MTProtoGenerator/assemblePackage(_:plan:)`` turns them into sources or
/// modules. See <doc:ExtendingEmission>.
@_spi(GeneratorInternals) public struct EmittedFile: Sendable {
  @_spi(GeneratorInternals) public var group: ModuleGroup
  @_spi(GeneratorInternals) public var file: GeneratedFile

  @_spi(GeneratorInternals) public init(group: ModuleGroup, file: GeneratedFile) {
    self.group = group
    self.file = file
  }
}

/// Generates Swift sources from a TL schema JSON document.
///
/// Generation is deterministic: the same schema bytes and options always
/// produce the same set of files with identical contents.
public struct MTProtoGenerator: Sendable {
  public var options: GeneratorOptions

  public init(options: GeneratorOptions) {
    self.options = options
  }

  /// Generates all files for `schemaData` (the JSON from
  /// <https://corefork.telegram.org/schema/json>), sorted by path — one
  /// module's worth of sources.
  public func generate(schemaData: Data) throws -> [GeneratedFile] {
    let resolved = try resolve(schemaData: schemaData)
    // Without a split, the only extra import is the root-`TL` module.
    let extraImports = options.rootNamespaceModule.map { [$0] } ?? []
    return try assemble(baseEmission(resolved: resolved, imports: { _ in extraImports }))
  }

  /// Generates the same schema as several modules re-exported by an umbrella
  /// module named ``GeneratorOptions/umbrellaModule``, so a build system can
  /// cache and rebuild the parts independently. Consumers still import only
  /// the umbrella.
  public func generatePackage(schemaData: Data) throws -> GeneratedPackage {
    guard let umbrella = options.umbrellaModule else { throw GeneratorError.missingUmbrellaModule }
    let resolved = try resolve(schemaData: schemaData)
    let namespaces = resolved.methodsByNamespace.map(\.namespace)
    let plan = ModuleSplitPlan(
      umbrella: umbrella, rootNamespaceModule: options.rootNamespaceModule,
      methodNamespaces: namespaces,
      clientNamespaces: options.generatesClient ? namespaces : [])
    return try assemblePackage(
      baseEmission(resolved: resolved, imports: plan.imports(for:)), plan: plan)
  }

  /// Decodes `schemaData`, drops ``GeneratorOptions/excludedNamespaces``, and
  /// resolves every TL name onto a Swift one.
  ///
  /// Every run starts here, including one that applies its own method selection
  /// afterwards — sharing the step is what keeps the exclusion from being
  /// skipped. See <doc:ExtendingEmission>.
  @_spi(GeneratorInternals) public func parse(schemaData: Data) throws -> ResolvedSchema {
    try ResolvedSchema(
      try TLSchemaJSON(data: schemaData).excluding(namespaces: options.excludedNamespaces))
  }

  /// ``parse(schemaData:)`` plus ``GeneratorOptions/selectedMethods``.
  private func resolve(schemaData: Data) throws -> ResolvedSchema {
    let resolved = try parse(schemaData: schemaData)
    guard let selected = options.selectedMethods else { return resolved }
    return try resolved.selecting(methods: selected)
  }

  // MARK: - Emission

  /// The files every run emits: the namespace declarations, one file per type,
  /// one per request struct, and — in `client` mode — the RPC client.
  ///
  /// `imports` supplies a group's import list, the only thing the module layout
  /// affects: which module a file lands in never changes its declarations.
  @_spi(GeneratorInternals) public func baseEmission(
    resolved: ResolvedSchema, imports: (ModuleGroup) -> [String]
  ) throws -> [EmittedFile] {
    let visibility = options.visibility.keyword
    var emitted: [EmittedFile] = []

    emitted.append(
      EmittedFile(
        group: .support,
        file: try resolved.namespacesFile(
          visibility: visibility, rootNamespaceModule: options.rootNamespaceModule)))
    for type in resolved.types {
      emitted.append(
        EmittedFile(
          group: .types,
          file: try resolved.typeFile(
            type, visibility: visibility, extraImports: imports(.types))))
    }
    for method in resolved.methods {
      let group = ModuleGroup.methods(namespace: method.namespace ?? "")
      emitted.append(
        EmittedFile(
          group: group,
          file: try resolved.methodFile(
            method, visibility: visibility, extraImports: imports(group))))
    }

    if options.generatesClient {
      emitted.append(
        EmittedFile(
          group: .clientCore,
          file: try resolved.clientCoreFile(
            visibility: visibility, extraImports: imports(.clientCore))))
      for (namespace, methods) in resolved.methodsByNamespace {
        let group = ModuleGroup.client(namespace: namespace)
        emitted.append(
          EmittedFile(
            group: group,
            file: try resolved.clientNamespaceFile(
              namespace: namespace, methods: methods, visibility: visibility,
              extraImports: imports(group))))
      }
    }
    return emitted
  }

  // MARK: - Assembly

  /// Uniquifies basenames, checks every file parses, and sorts by path — one
  /// module's worth of sources.
  @_spi(GeneratorInternals) public func assemble(
    _ emitted: [EmittedFile]
  ) throws -> [GeneratedFile] {
    var files = emitted.map(\.file)
    uniquifyBasenames(&files)
    for file in files {
      try validate(file)
    }
    return files.sorted { $0.path < $1.path }
  }

  /// Lays `emitted` out as the modules of `plan`, stripping each group's
  /// directory prefix from its files.
  @_spi(GeneratorInternals) public func assemblePackage(
    _ emitted: [EmittedFile], plan: ModuleSplitPlan
  ) throws -> GeneratedPackage {
    var filesByGroup: [ModuleGroup: [GeneratedFile]] = [:]
    for emission in emitted {
      var file = emission.file
      for prefix in plan.strippedPathPrefixes(for: emission.group) where file.path.hasPrefix(prefix)
      {
        file.path = String(file.path.dropFirst(prefix.count))
        break
      }
      filesByGroup[emission.group, default: []].append(file)
    }

    var modules: [GeneratedModule] = []
    for group in plan.groups {
      var files = filesByGroup[group] ?? []
      guard !files.isEmpty else { continue }
      uniquifyBasenames(&files)
      for file in files {
        try validate(file)
      }
      modules.append(
        GeneratedModule(
          name: plan.moduleName(for: group),
          directory: group.nameSuffix,
          dependencies: plan.dependencies(for: group).map(plan.moduleName(for:)),
          externalDependencies: plan.externalDependencies,
          files: files.sorted { $0.path < $1.path }))
    }
    modules.append(plan.umbrellaModule())
    return GeneratedPackage(umbrella: plan.umbrella, modules: modules)
  }

  /// Makes every basename unique ignoring case — SwiftPM derives object file names
  /// from them, on a possibly case-insensitive filesystem. Later claimants, in
  /// deterministic emission order, get `_` appended.
  private func uniquifyBasenames(_ files: inout [GeneratedFile]) {
    var claimed: Set<String> = []
    for index in files.indices {
      let path = files[index].path
      guard let slash = path.lastIndex(of: "/"), path.hasSuffix(".swift") else {
        claimed.insert(path.lowercased())
        continue
      }
      var basename = String(path[path.index(after: slash)...].dropLast(".swift".count))
      while !claimed.insert((basename + ".swift").lowercased()).inserted {
        basename += "_"
      }
      files[index].path = "\(path[..<slash])/\(basename).swift"
    }
  }

  /// Re-parses an emitted file and fails generation on any syntax error —
  /// invalid output should never reach the output directory.
  private func validate(_ file: GeneratedFile) throws {
    let parsed = Parser.parse(source: file.contents)
    guard parsed.hasError else { return }
    let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: parsed)
      .prefix(5)
      .map { diagnostic in
        let location = diagnostic.location(
          converter: SourceLocationConverter(fileName: file.path, tree: parsed))
        return "\(location.line):\(location.column): \(diagnostic.message)"
      }
      .joined(separator: "; ")
    throw GeneratorError.emittedInvalidSwift(path: file.path, details: diagnostics)
  }
}
