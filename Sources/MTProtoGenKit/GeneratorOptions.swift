/// Configuration for one generation run.
public struct GeneratorOptions: Sendable {
  /// What to emit alongside the schema types.
  public enum Mode: String, CaseIterable, Sendable {
    /// The schema types and method request structs only.
    case types
    /// Also a `TLClient` exposing every method as an `async` function.
    case client
  }

  /// Access level applied to every generated declaration.
  public enum Visibility: String, CaseIterable, Sendable {
    case `public`
    case package
    case `internal`
    case `private`

    /// The modifier as written in source. `internal` is written explicitly, so
    /// the output is self-documenting.
    @_spi(GeneratorInternals) public var keyword: String { rawValue }
  }

  public var mode: Mode
  public var visibility: Visibility
  /// The module that declares the root `TL` namespace enum, when this run does
  /// not. See <doc:ExtendingASchema>.
  public var rootNamespaceModule: String?
  /// Only these TL methods (e.g. `auth.sendCode`), plus the types they reach;
  /// `nil` generates everything. See <doc:SelectingMethods>.
  public var selectedMethods: Set<String>?
  /// TL namespaces dropped from the schema before name resolution. Empty by
  /// default. See <doc:ExcludingNamespaces>.
  public var excludedNamespaces: Set<String>
  /// The umbrella module's name, read by
  /// ``MTProtoGenerator/generatePackage(schemaData:)``. See
  /// <doc:SplittingIntoModules>.
  public var umbrellaModule: String?

  public init(
    mode: Mode, visibility: Visibility = .public, rootNamespaceModule: String? = nil,
    selectedMethods: Set<String>? = nil, excludedNamespaces: Set<String> = [],
    umbrellaModule: String? = nil
  ) {
    self.mode = mode
    self.visibility = visibility
    self.rootNamespaceModule = rootNamespaceModule
    self.selectedMethods = selectedMethods
    self.excludedNamespaces = excludedNamespaces
    self.umbrellaModule = umbrellaModule
  }

  @_spi(GeneratorInternals) public var generatesClient: Bool { mode == .client }
}
