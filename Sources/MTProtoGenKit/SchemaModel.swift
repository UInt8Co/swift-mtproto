#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// MARK: - JSON schema model

/// The TL schema as served by <https://corefork.telegram.org/schema/json>:
/// `{"constructors": [...], "methods": [...]}` where every combinator has a
/// signed-decimal `id`, a `predicate` (constructors) or `method` (methods)
/// name, `params`, and a result `type`.
public struct TLSchemaJSON: Decodable, Sendable {
  public var constructors: [Combinator]
  public var methods: [Combinator]

  public struct Combinator: Decodable, Sendable {
    public var id: String
    public var predicate: String?
    public var method: String?
    public var params: [Param]
    public var type: String

    /// The combinator name: `predicate` for constructors, `method` for methods.
    public var name: String { predicate ?? method ?? "" }

    /// The 32-bit constructor number (the JSON stores it as a signed decimal).
    public func constructorID() throws -> UInt32 {
      guard let signed = Int32(id) else {
        throw GeneratorError.invalidConstructorID(combinator: name, id: id)
      }
      return UInt32(bitPattern: signed)
    }

    /// The TL declaration this combinator was parsed from, reconstructed for
    /// documentation comments: `auth.sendCode#a677244f phone_number:string … = auth.SentCode`.
    public func tlDeclaration() throws -> String {
      let id = try constructorID()
      var hex = String(id, radix: 16)
      if hex.count < 8 { hex = String(repeating: "0", count: 8 - hex.count) + hex }
      let fields = params.map { " \($0.name):\($0.type)" }.joined()
      return "\(name)#\(hex)\(fields) = \(type)"
    }
  }

  public struct Param: Decodable, Sendable {
    public var name: String
    public var type: String
  }

  public init(data: Data) throws {
    do {
      self = try JSONDecoder().decode(TLSchemaJSON.self, from: data)
    } catch {
      throw GeneratorError.invalidSchemaJSON(underlying: String(describing: error))
    }
  }

  /// The schema without the combinators whose TL namespace is in `namespaces`.
  ///
  /// Filtering here, before name resolution, is what makes an exclusion
  /// invisible: the namespace claims no Swift names, so dropping it cannot rename
  /// a real declaration. See <doc:ExcludingNamespaces>.
  public func excluding(namespaces: Set<String>) -> TLSchemaJSON {
    guard !namespaces.isEmpty else { return self }
    func isExcluded(_ combinator: Combinator) -> Bool {
      guard let namespace = Naming.namespace(of: combinator.name) else { return false }
      return namespaces.contains(namespace)
    }
    var filtered = self
    filtered.constructors = constructors.filter { !isExcluded($0) }
    filtered.methods = methods.filter { !isExcluded($0) }
    return filtered
  }
}

// MARK: - Parsed TL types

/// A TL value type as it appears in a field or result position.
public indirect enum TLValueType: Equatable, Sendable {
  case int32  // int
  case int64  // long
  case double
  case string
  case bytes
  case int128
  case int256
  case bool  // boxed Bool
  case vector(TLValueType)  // Vector<T>
  /// A reference to a schema-defined type, e.g. `auth.SentCode`.
  case named(String)
  /// `Object` — the MTProto pseudo-type for any boxed object, carried as raw
  /// serialized bytes (`TLAnyObject` at runtime).
  case object
  /// `!X` — a generic query (the wrapped function in `invokeWithLayer` etc.).
  case genericQuery

  /// Parses a TL type expression (without any `flags.N?` prefix).
  /// Returns `nil` for `true`, which is only meaningful as a conditional.
  ///
  /// A leading `%` (bare-type marker) is stripped here; bareness is tracked
  /// separately on the field (see ``TLField/parse(_:combinator:)``). Both the
  /// boxed `Vector<T>` and the bare `vector<T>` spellings parse to
  /// ``vector(_:)`` — again, bareness lives on the field.
  static func parse(_ text: some StringProtocol) -> TLValueType? {
    if text.hasPrefix("%") {
      return parse(text.dropFirst())
    }
    switch text {
    case "int": return .int32
    case "long": return .int64
    case "double": return .double
    case "string": return .string
    case "bytes": return .bytes
    case "int128": return .int128
    case "int256": return .int256
    case "Bool": return .bool
    case "Object": return .object
    case "!X", "X": return .genericQuery
    case "true": return nil
    default:
      if let inner = vectorElementText(text) {
        guard let element = parse(inner) else { return nil }
        return .vector(element)
      }
      return .named(String(text))
    }
  }

  /// The element text of a `Vector<T>` / `vector<T>` (boxed or bare) type
  /// expression, or `nil` if `text` is not a vector.
  static func vectorElementText(_ text: some StringProtocol) -> String? {
    for prefix in ["Vector<", "vector<"] where text.hasPrefix(prefix) && text.hasSuffix(">") {
      return String(text.dropFirst(prefix.count).dropLast())
    }
    return nil
  }

  /// Whether the TL type expression is serialized in bare form: a `%`-prefixed
  /// type, or the lowercase `vector<…>` (a bare vector — count and elements
  /// without the `0x1cb5c415` constructor).
  static func isBareSpelling(_ text: some StringProtocol) -> Bool {
    text.hasPrefix("%") || text.hasPrefix("vector<")
  }

  /// Whether a vector's *element* type is serialized bare (each element without
  /// its own constructor number). True when the element is a `%`-prefixed type
  /// or a bare constructor reference — a name whose final component is
  /// lowercase-initial, e.g. `future_salt` in `vector<future_salt>`. The TL
  /// primitives are bare by nature (their bare and boxed forms are identical),
  /// so they are *not* flagged: this keeps `Vector<int>` etc. on the plain
  /// boxed-vector encode path. Non-vectors are never element-bare.
  static func isBareElementSpelling(_ text: some StringProtocol) -> Bool {
    guard let element = vectorElementText(text) else { return false }
    if element.hasPrefix("%") { return true }
    let finalComponent = element.split(separator: ".").last.map(String.init) ?? element
    guard let first = finalComponent.first, first.isLowercase else { return false }
    switch finalComponent {
    case "int", "long", "double", "string", "bytes", "int128", "int256", "true":
      return false
    default:
      return true
    }
  }

  var isGenericQuery: Bool {
    if case .genericQuery = self { return true }
    return false
  }
}

/// One field of a combinator, with its conditionality resolved.
public struct TLField: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// `flags:#` — a bitfield recomputed from the conditional fields.
    case flagsBitfield
    /// A regular field.
    case plain(TLValueType)
    /// `name:flags.N?Type`. A `wrapped` of `nil` means `flags.N?true`:
    /// the bit itself is the value and nothing goes on the wire.
    case conditional(flagsField: String, bit: Int, wrapped: TLValueType?)
  }

  /// The raw TL field name (snake_case).
  public var tlName: String
  public var kind: Kind
  /// Whether the field is serialized in bare form (a `%`-prefixed type or a
  /// lowercase `vector<…>`). Emitted as `@TLBare`.
  public var isBare: Bool = false
  /// Whether the field is a vector whose *elements* are bare (a bare-constructor
  /// or `%`-prefixed element type, e.g. `vector<future_salt>`). Emitted as
  /// `@TLBareElements`.
  public var isBareElement: Bool = false

  static func parse(_ param: TLSchemaJSON.Param, combinator: String) throws -> TLField {
    if param.type == "#" {
      return TLField(tlName: param.name, kind: .flagsBitfield)
    }
    if let question = param.type.firstIndex(of: "?") {
      let condition = param.type[..<question]
      let payload = param.type[param.type.index(after: question)...]
      guard let dot = condition.firstIndex(of: "."),
        let bit = Int(condition[condition.index(after: dot)...]),
        (0...31).contains(bit)
      else {
        throw GeneratorError.unsupportedFieldType(
          combinator: combinator, field: param.name, type: param.type)
      }
      let flagsField = String(condition[..<dot])
      let wrapped = TLValueType.parse(payload)
      if wrapped?.isGenericQuery == true {
        throw GeneratorError.unsupportedFieldType(
          combinator: combinator, field: param.name, type: param.type)
      }
      return TLField(
        tlName: param.name,
        kind: .conditional(flagsField: flagsField, bit: bit, wrapped: wrapped),
        isBare: TLValueType.isBareSpelling(payload),
        isBareElement: TLValueType.isBareElementSpelling(payload))
    }
    guard let value = TLValueType.parse(param.type) else {
      throw GeneratorError.unsupportedFieldType(
        combinator: combinator, field: param.name, type: param.type)
    }
    return TLField(
      tlName: param.name, kind: .plain(value),
      isBare: TLValueType.isBareSpelling(param.type),
      isBareElement: TLValueType.isBareElementSpelling(param.type))
  }
}

// MARK: - Errors

public enum GeneratorError: Error, Equatable, CustomStringConvertible {
  case invalidSchemaJSON(underlying: String)
  case invalidConstructorID(combinator: String, id: String)
  case unsupportedFieldType(combinator: String, field: String, type: String)
  case unknownTypeReference(combinator: String, type: String)
  case missingFlagsField(combinator: String, field: String, flagsField: String)
  case unknownSelectedMethod(name: String)
  case invalidMethodManifest(line: Int, reason: String)
  case emittedInvalidSwift(path: String, details: String)
  case missingUmbrellaModule

  public var description: String {
    switch self {
    case .invalidSchemaJSON(let underlying):
      return "the schema JSON could not be decoded: \(underlying)"
    case .invalidConstructorID(let combinator, let id):
      return "combinator '\(combinator)' has an invalid constructor id '\(id)'"
    case .unsupportedFieldType(let combinator, let field, let type):
      return "combinator '\(combinator)' field '\(field)' has unsupported type '\(type)'"
    case .unknownTypeReference(let combinator, let type):
      return "combinator '\(combinator)' references unknown type '\(type)'"
    case .missingFlagsField(let combinator, let field, let flagsField):
      return
        "combinator '\(combinator)' field '\(field)' references missing flags field '\(flagsField)'"
    case .unknownSelectedMethod(let name):
      return "selected method '\(name)' is not in the schema"
    case .invalidMethodManifest(let line, let reason):
      return line > 0
        ? "method manifest line \(line): \(reason)"
        : "method manifest: \(reason)"
    case .emittedInvalidSwift(let path, let details):
      return "generated file '\(path)' is not valid Swift: \(details)"
    case .missingUmbrellaModule:
      return "a split generation run needs an umbrella module name"
    }
  }
}
