import ArgumentParser
import MTProtoGenKit
import SystemPackage

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@main
struct MTProtoGenSwift: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mtproto-gen-swift",
    abstract: "Generates Swift types and an RPC client from the Telegram TL schema.",
    discussion: """
      Downloads the MTProto API schema (JSON) and emits one Swift file per TL \
      type and per RPC method, built on the TLCoding runtime and macros. \
      Generation is deterministic: the same schema and options always produce \
      byte-identical output.
      """
  )

  @Option(
    name: .customLong("schema-url"),
    help: "URL of the TL schema JSON. Supports https:// and file:// (or a plain path).")
  var schemaURL: String = "https://corefork.telegram.org/schema/json"

  @Option(name: [.short, .long], help: "Directory the generated sources are written into.")
  var output: String

  @Option(
    help:
      "What to generate alongside the schema types: \(valueList(GeneratorOptions.Mode.self)).")
  var mode: GeneratorOptions.Mode

  @Option(
    help:
      "Access level of the generated declarations: \(valueList(GeneratorOptions.Visibility.self)).")
  var visibility: GeneratorOptions.Visibility = .public

  @Option(
    name: .customLong("method"),
    help: ArgumentHelp(
      "Generate only this TL method (repeatable), plus the types it transitively needs.",
      discussion: """
        Names are resolved against the full schema before selection, so the \
        subset keeps exactly the Swift names a full generation would produce. \
        Omit to generate every method.
        """,
      valueName: "tl-name"))
  var methods: [String] = []

  @Option(
    name: .customLong("methods-file"),
    help: ArgumentHelp(
      "File listing the TL methods to generate, one per line.",
      discussion: """
        Blank lines and `#` comments are ignored, so the list can say why an \
        entry is there. Unions with any --method values. Selection works the \
        same either way: names resolve against the full schema first, and the \
        types they transitively need come along.
        """,
      valueName: "path"))
  var methodsFile: String?

  @Option(
    name: .customLong("exclude-namespace"),
    help: ArgumentHelp(
      "Drop every combinator in this TL namespace (repeatable).",
      discussion: """
        For the vendor entries a third-party schema splices in — mtcute's \
        `mtcute.*` dummies, for instance — which are client-internal and must \
        never reach generated code. Applied before name resolution, so an \
        excluded namespace claims no Swift names and cannot rename anything.
        """,
      valueName: "tl-namespace"))
  var excludeNamespace: [String] = []

  @Option(
    name: .customLong("root-namespace-module"),
    help: """
      Module that already declares the root TL namespace enum (because another \
      schema was generated into it). Generated files import it, and \
      Support/Namespaces.swift re-exports it instead of redeclaring TL.
      """)
  var rootNamespaceModule: String?

  @Option(
    name: .customLong("split-modules"),
    help: ArgumentHelp(
      "Emit the schema as several modules re-exported by an umbrella module of this name.",
      discussion: """
        Without it the output is one module's worth of sources. With it, the \
        output directory gets one subdirectory per module (Support, Types, \
        Methods<Namespace>, Client<Namespace>, Umbrella) plus a \
        modules.json manifest naming each module, its directory and its \
        dependencies — so a build system can declare the targets and cache \
        them independently. Consumers still import only the umbrella, which \
        re-exports every part.
        """,
      valueName: "umbrella-module"))
  var splitModules: String?

  func validate() throws {
    // The submodules append a suffix to this name, so it has to be an
    // identifier on its own.
    if let umbrella = splitModules {
      let isIdentifier =
        !umbrella.isEmpty && umbrella.first?.isNumber == false
        && umbrella.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
      guard isIdentifier else {
        throw ValidationError("--split-modules '\(umbrella)' is not a Swift module name.")
      }
    }
  }

  /// The `--method` values unioned with `--methods-file`'s, or `nil` for "every
  /// method" when neither was given.
  private func selectedMethods() throws -> Set<String>? {
    var selected = Set(methods)
    if let path = methodsFile {
      selected.formUnion(try MethodManifest.parse(try SchemaLoader.readText(at: path)))
    }
    return selected.isEmpty ? nil : selected
  }

  func run() async throws {
    if visibility == .private {
      _ = try? FileDescriptor.standardError.writeAll(
        """
        warning: --visibility private makes declarations fileprivate at file \
        scope; the generated files can only compile if concatenated into a \
        single file. Consider 'internal'.\n
        """.utf8)
    }
    let schemaData = try await SchemaLoader.load(from: schemaURL)
    let selected = try selectedMethods()
    let options = GeneratorOptions(
      mode: mode, visibility: visibility,
      rootNamespaceModule: rootNamespaceModule,
      selectedMethods: selected,
      excludedNamespaces: Set(excludeNamespace),
      umbrellaModule: splitModules)
    let generator = MTProtoGenerator(options: options)
    let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)
    if splitModules != nil {
      let package = try generator.generatePackage(schemaData: schemaData)
      try OutputWriter.write(package, to: outputDirectory)
      summarize(package)
    } else {
      let files = try generator.generate(schemaData: schemaData)
      try OutputWriter.write(files, to: outputDirectory)
      summarize(files)
    }
  }

  private func summarize(_ files: [GeneratedFile]) {
    var counts: [String: Int] = [:]
    for file in files {
      let group = file.path.split(separator: "/").first.map(String.init) ?? "."
      counts[group, default: 0] += 1
    }
    let breakdown = counts.keys.sorted()
      .map { "\($0): \(counts[$0]!)" }
      .joined(separator: ", ")
    print("Generated \(files.count) files into \(output) (\(breakdown)).")
  }

  private func summarize(_ package: GeneratedPackage) {
    let total = package.modules.reduce(0) { $0 + $1.files.count }
    let breakdown = package.modules
      .map { "\($0.directory): \($0.files.count)" }
      .joined(separator: ", ")
    print(
      "Generated \(total) files into \(output) as \(package.modules.count) modules "
        + "under \(package.umbrella) (\(breakdown)).")
  }
}

private func valueList<Value: CaseIterable & RawRepresentable>(
  _ type: Value.Type
) -> String where Value.RawValue == String {
  Value.allCases.map(\.rawValue).joined(separator: ", ")
}

extension GeneratorOptions.Mode: ExpressibleByArgument {}
extension GeneratorOptions.Visibility: ExpressibleByArgument {}
