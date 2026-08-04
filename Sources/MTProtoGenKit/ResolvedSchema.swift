/// A Swift declaration name inside the generated `TL` root namespace.
public struct SwiftName: Equatable, Sendable {
  /// Backwards-compat layer segment (`L225`), inserted between `TL` and the
  /// namespace, or `nil` for the latest-layer declarations.
  public var layerPrefix: String? = nil
  /// Capitalized namespace enum name (`Auth`), or `nil` for the root scope.
  public var namespace: String?
  /// The declaration's own name, e.g. `SentCode`.
  public var local: String

  @_spi(GeneratorInternals) public init(
    layerPrefix: String? = nil, namespace: String? = nil, local: String
  ) {
    self.layerPrefix = layerPrefix
    self.namespace = namespace
    self.local = local
  }

  /// `TL.Auth.SentCode` / `TL.L225.Auth.SentCode` — how generated code refers
  /// to the declaration. Always fully qualified from the root.
  public var qualified: String {
    "TL." + (layerPrefix.map { "\($0)." } ?? "") + (namespace.map { "\($0)." } ?? "") + local
  }

  /// `TL` / `TL.Auth` / `TL.L225.Auth` — the extension target the declaration
  /// nests in.
  public var scope: String {
    "TL" + (layerPrefix.map { ".\($0)" } ?? "") + (namespace.map { ".\($0)" } ?? "")
  }
}

/// The schema after name resolution: combinators parsed, builtin types
/// stripped, and every TL name mapped onto a deterministic Swift name nested
/// under the root `TL` namespace enum.
public struct ResolvedSchema: Sendable {
  /// TL types TLCoding provides natively, so they are never generated: `Bool`,
  /// `Vector t`, `Object`, and the constructor-only `True` / `Null`.
  static let builtinTypes: Set<String> = ["Bool", "True", "Null", "Vector t", "Object"]

  /// Identifiers a generated declaration must not claim: generated code names
  /// them unqualified inside `TL` scopes, so a member would shadow them.
  static let reservedMemberNames: Set<String> = [
    "TL", "TLCoding", "Swift", "Type",
    "Int32", "Int64", "UInt32", "UInt64", "Double", "String", "Data", "Bool",
    "TLInt128", "TLInt256", "TLWriter", "TLReader", "TLError", "TLFunction",
    "TLEncodable", "TLDecodable", "TLConstructed", "TLAnyObject",
    "Equatable", "Sendable", "Optional", "Array",
  ]

  public struct Constructor: Sendable {
    public var tlName: String
    public var constructorID: UInt32
    public var fields: [TLField]
    public var tlDeclaration: String
    /// Swift struct name, e.g. `TL.InputPeerEmpty` / `TL.Auth.SentCode`.
    public var swiftName: SwiftName
    /// Swift enum case name (only used for multi-constructor types).
    public var caseName: String
  }

  public struct TypeDefinition: Sendable {
    public var tlName: String
    public var constructors: [Constructor]
    /// `nil` for single-constructor types (represented by the struct itself);
    /// the Swift enum name otherwise, e.g. `TL.InputPeerType`.
    public var swiftEnumName: SwiftName?
    /// The Swift name fields of this type resolve to.
    public var swiftReferenceName: SwiftName {
      swiftEnumName ?? constructors[0].swiftName
    }
  }

  public struct Method: Sendable {
    public var tlName: String
    public var constructorID: UInt32
    public var fields: [TLField]
    public var tlDeclaration: String
    /// Swift struct name of the request, e.g. `TL.Auth.SendCode`.
    public var swiftName: SwiftName
    public var returnType: TLValueType
    /// `true` for the `invokeWithLayer`-style wrappers (`!X` query, `X` result).
    public var isGeneric: Bool
    /// TL namespace (`auth` in `auth.sendCode`), `nil` for the global one.
    public var namespace: String?
    /// Method name within its namespace, camel-cased and keyword-escaped.
    public var swiftMethodName: String
  }

  /// Type definitions, ordered by first constructor appearance in the schema.
  public var types: [TypeDefinition]
  /// Methods in schema order.
  public var methods: [Method]
  /// Capitalized namespace enum names, sorted.
  public var namespaceEnumNames: [String]
  /// TL type name → Swift name (for field/result positions).
  @_spi(GeneratorInternals) public var typeReferences: [String: SwiftName]
  /// TL constructor (predicate) name → Swift struct name. Used to resolve
  /// bare element references like `vector<future_salt>` / `%future_salt`,
  /// which name a constructor rather than a boxed type.
  @_spi(GeneratorInternals) public var constructorReferences: [String: SwiftName] = [:]

  public init(_ schema: TLSchemaJSON) throws {
    // Pass 1: parse combinators and collect the namespaces.
    var typeOrder: [String] = []
    var rawConstructorsByType: [String: [TLSchemaJSON.Combinator]] = [:]
    for combinator in schema.constructors {
      guard combinator.predicate != nil else { continue }
      if Self.builtinTypes.contains(combinator.type) { continue }
      if rawConstructorsByType[combinator.type] == nil {
        typeOrder.append(combinator.type)
      }
      rawConstructorsByType[combinator.type, default: []].append(combinator)
    }

    var allTLNames: [String] = typeOrder
    for combinators in rawConstructorsByType.values {
      allTLNames += combinators.map(\.name)
    }
    allTLNames += schema.methods.compactMap(\.method)
    var namespaceEnums: Set<String> = []
    for name in allTLNames {
      if let namespace = Naming.namespace(of: name) {
        namespaceEnums.insert(Naming.namespaceEnumName(namespace))
      }
    }
    self.namespaceEnumNames = namespaceEnums.sorted()

    // Pass 2: claim Swift names deterministically. Reserved identifiers and
    // (in the root scope) the namespace enum names are taken; a colliding
    // declaration gets `_` appended until its name is free.
    var claimed: [String: Set<String>] = [:]  // scope key ("" = root) → names
    claimed[""] = namespaceEnums
    func claim(_ candidate: String, namespace: String?) -> String {
      let key = namespace ?? ""
      var name = candidate
      while Self.reservedMemberNames.contains(name) || claimed[key, default: []].contains(name) {
        name += "_"
      }
      claimed[key, default: []].insert(name)
      return name
    }
    func swiftName(forTL tlName: String, suffix: String = "") -> SwiftName {
      let namespace = Naming.namespace(of: tlName).map(Naming.namespaceEnumName)
      let candidate = Naming.capitalizedFirst(Naming.camelCase(Naming.localName(of: tlName)))
      return SwiftName(
        namespace: namespace, local: claim(candidate + suffix, namespace: namespace))
    }

    var constructorNames: [String: SwiftName] = [:]  // predicate → name
    for type in typeOrder {
      for combinator in rawConstructorsByType[type]! {
        constructorNames[combinator.name] = swiftName(forTL: combinator.name)
      }
    }
    self.constructorReferences = constructorNames
    var typeEnumNames: [String: SwiftName] = [:]  // TL type → enum name
    for type in typeOrder where rawConstructorsByType[type]!.count > 1 {
      typeEnumNames[type] = swiftName(forTL: type, suffix: "Type")
    }
    var methodNames: [String: SwiftName] = [:]  // method → name
    for combinator in schema.methods {
      guard let method = combinator.method else { continue }
      methodNames[method] = swiftName(forTL: method)
    }

    // Pass 3: build the resolved model.
    var types: [TypeDefinition] = []
    var typeReferences: [String: SwiftName] = [:]
    for tlName in typeOrder {
      let typeNamespace = Naming.namespace(of: tlName)
      let constructors = try rawConstructorsByType[tlName]!.map { combinator in
        let predicate = combinator.name
        // Constructors almost always live in their type's namespace; the
        // case name drops the shared namespace, and keeps the full flattened
        // predicate otherwise.
        let caseName =
          Naming.namespace(of: predicate) == typeNamespace
          ? Naming.caseName(Naming.localName(of: predicate))
          : Naming.caseName(predicate)
        return Constructor(
          tlName: predicate,
          constructorID: try combinator.constructorID(),
          fields: try combinator.params.map { try TLField.parse($0, combinator: predicate) },
          tlDeclaration: try combinator.tlDeclaration(),
          swiftName: constructorNames[predicate]!,
          caseName: caseName
        )
      }
      let definition = TypeDefinition(
        tlName: tlName,
        constructors: constructors,
        swiftEnumName: typeEnumNames[tlName]
      )
      types.append(definition)
      typeReferences[tlName] = definition.swiftReferenceName
    }
    self.types = types
    self.typeReferences = typeReferences

    self.methods = try schema.methods.compactMap { combinator -> Method? in
      guard let name = combinator.method else { return nil }
      let fields = try combinator.params.map { try TLField.parse($0, combinator: name) }
      let isGeneric =
        combinator.type == "X"
        || fields.contains {
          if case .plain(.genericQuery) = $0.kind { return true }
          return false
        }
      guard let returnType = TLValueType.parse(combinator.type) else {
        throw GeneratorError.unsupportedFieldType(
          combinator: name, field: "<result>", type: combinator.type)
      }
      return Method(
        tlName: name,
        constructorID: try combinator.constructorID(),
        fields: fields,
        tlDeclaration: try combinator.tlDeclaration(),
        swiftName: methodNames[name]!,
        returnType: returnType,
        isGeneric: isGeneric,
        namespace: Naming.namespace(of: name),
        swiftMethodName: Naming.escaped(Naming.camelCase(Naming.localName(of: name)))
      )
    }
  }

  /// Resolves a TL type/constructor name to the Swift name a reference should
  /// use. Returns `nil` when the name is not a schema type (the caller then
  /// throws).
  @_spi(GeneratorInternals) public typealias TypeResolver = (String) -> SwiftName?

  /// The reference resolver for normal (single-layer) generation: a TL name
  /// maps to this schema's own boxed-type or constructor Swift name.
  @_spi(GeneratorInternals) public func baseResolver() -> TypeResolver {
    { [typeReferences, constructorReferences] in typeReferences[$0] ?? constructorReferences[$0] }
  }

  /// The Swift type for a TL value position, fully qualified from the `TL`
  /// root for schema-defined types.
  ///
  /// - `genericParameter` is substituted for `!X` (used by the generic
  ///   `invokeWith…` wrappers).
  public func swiftType(
    for value: TLValueType, in combinator: String, genericParameter: String = "Query"
  ) throws -> String {
    try swiftType(
      for: value, in: combinator, genericParameter: genericParameter, resolve: baseResolver())
  }

  /// As ``swiftType(for:in:genericParameter:)``, resolving schema-defined
  /// references through `resolve` — for an emitter whose references may point at
  /// `TL.*` or at another layer's `TL.L<N>.*`.
  @_spi(GeneratorInternals) public func swiftType(
    for value: TLValueType, in combinator: String, genericParameter: String = "Query",
    resolve: TypeResolver
  ) throws -> String {
    switch value {
    case .int32: return "Int32"
    case .int64: return "Int64"
    case .double: return "Double"
    case .string: return "String"
    case .bytes: return "Data"
    case .int128: return "TLInt128"
    case .int256: return "TLInt256"
    case .bool: return "Bool"
    case .vector(let element):
      return
        "[\(try swiftType(for: element, in: combinator, genericParameter: genericParameter, resolve: resolve))]"
    case .named(let tlName):
      // A field/result position usually names a boxed TL type; bare element
      // references (`vector<future_salt>`) instead name a constructor.
      guard let swiftName = resolve(tlName) else {
        throw GeneratorError.unknownTypeReference(combinator: combinator, type: tlName)
      }
      return swiftName.qualified
    case .object:
      return "TLAnyObject"
    case .genericQuery:
      return genericParameter
    }
  }

  /// The schema reduced to `selected` methods plus every type transitively
  /// reachable from their fields and results.
  ///
  /// Names are already resolved against the full schema, so a surviving
  /// declaration keeps the name a full run would give it. See
  /// <doc:SelectingMethods>.
  public func selecting(methods selected: Set<String>) throws -> ResolvedSchema {
    let known = Set(methods.map(\.tlName))
    if let missing = selected.subtracting(known).sorted().first {
      throw GeneratorError.unknownSelectedMethod(name: missing)
    }

    // The TL type that declares each constructor, to resolve bare element
    // references (`vector<future_salt>`) that name a constructor rather
    // than its boxed type.
    var typeDeclaring: [String: String] = [:]
    let definitions = Dictionary(uniqueKeysWithValues: types.map { ($0.tlName, $0) })
    for type in types {
      for constructor in type.constructors {
        typeDeclaring[constructor.tlName] = type.tlName
      }
    }

    var reachable: Set<String> = []
    var worklist: [TLValueType] = []
    func enqueue(_ fields: [TLField]) {
      for field in fields {
        switch field.kind {
        case .flagsBitfield: break
        case .plain(let value): worklist.append(value)
        case .conditional(_, _, let wrapped):
          if let wrapped { worklist.append(wrapped) }
        }
      }
    }
    let selectedMethods = methods.filter { selected.contains($0.tlName) }
    for method in selectedMethods {
      enqueue(method.fields)
      worklist.append(method.returnType)
    }
    while let value = worklist.popLast() {
      switch value {
      case .vector(let element):
        worklist.append(element)
      case .named(let name):
        // Builtins (`Bool`, `Object`, …) resolve to neither and need no file.
        guard let tlName = definitions[name] != nil ? name : typeDeclaring[name] else { continue }
        guard reachable.insert(tlName).inserted else { continue }
        for constructor in definitions[tlName]!.constructors {
          enqueue(constructor.fields)
        }
      default:
        break
      }
    }

    var subset = self
    subset.methods = selectedMethods
    subset.types = types.filter { reachable.contains($0.tlName) }
    // Keep only the namespace enums that still have a member.
    var liveNamespaces: Set<String> = []
    var survivingTLNames = subset.methods.map(\.tlName)
    for type in subset.types {
      survivingTLNames.append(type.tlName)
      survivingTLNames += type.constructors.map(\.tlName)
    }
    for name in survivingTLNames {
      if let namespace = Naming.namespace(of: name) {
        liveNamespaces.insert(Naming.namespaceEnumName(namespace))
      }
    }
    subset.namespaceEnumNames = namespaceEnumNames.filter(liveNamespaces.contains)
    return subset
  }

  /// The TL type and constructor names `fields` reference, recursing through
  /// vectors; bitfields and primitives contribute nothing.
  @_spi(GeneratorInternals) public func referencedTypeNames(of fields: [TLField]) -> Set<String> {
    var names: Set<String> = []
    var worklist: [TLValueType] = []
    for field in fields {
      switch field.kind {
      case .flagsBitfield: break
      case .plain(let value): worklist.append(value)
      case .conditional(_, _, let wrapped): if let wrapped { worklist.append(wrapped) }
      }
    }
    while let value = worklist.popLast() {
      switch value {
      case .vector(let element): worklist.append(element)
      case .named(let name): names.insert(name)
      default: break
      }
    }
    return names
  }

  /// Methods grouped by namespace; namespaces sorted, methods in schema
  /// order. Global (un-namespaced) methods come under the key `""`.
  public var methodsByNamespace: [(namespace: String, methods: [Method])] {
    var order: [String] = []
    var groups: [String: [Method]] = [:]
    for method in methods {
      let key = method.namespace ?? ""
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(method)
    }
    return order.sorted().map { ($0, groups[$0]!) }
  }
}
