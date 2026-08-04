import SwiftSyntax
import SwiftSyntaxBuilder

/// Emission of the schema-derived declarations: one `@TLObject` struct per
/// constructor and method, one `@TLType` enum per multi-constructor type. The
/// TLCoding macros generate the wire-format code; this only lays out properties,
/// attributes and names.
extension ResolvedSchema {
  // MARK: - Properties

  /// A Swift stored property derived from one TL field.
  struct EmittedProperty {
    /// `@TLFlags` / `@TLConditional("flags", bit: N)` attribute, if any.
    var attribute: String?
    /// Escaped Swift name.
    var name: String
    /// Swift type as written, including a trailing `?` for conditionals.
    var type: String
    /// Default value for the declaration and the initializer.
    var defaultValue: String?
    var isFlagsBitfield: Bool
    var field: TLField
  }

  func emittedProperties(
    of fields: [TLField], in combinator: String, genericParameter: String = "Query",
    resolve: TypeResolver? = nil
  ) throws -> [EmittedProperty] {
    let resolve = resolve ?? baseResolver()
    let bitfieldNames = Set(
      fields.compactMap { $0.kind == .flagsBitfield ? $0.tlName : nil })
    return try fields.map { field in
      let name = Naming.propertyName(field.tlName)
      func combined(_ attributes: String?...) -> String? {
        let joined = attributes.compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
      }
      // `@TLBare` drops the field's own constructor number, `@TLBareElements`
      // each element's.
      let bareAttribute = combined(
        field.isBare ? "@TLBare" : nil,
        field.isBareElement ? "@TLBareElements" : nil)
      switch field.kind {
      case .flagsBitfield:
        return EmittedProperty(
          attribute: "@TLFlags",
          name: name, type: "UInt32", defaultValue: "0",
          isFlagsBitfield: true, field: field)
      case .plain(let value):
        return EmittedProperty(
          attribute: bareAttribute,
          name: name,
          type: try swiftType(
            for: value, in: combinator, genericParameter: genericParameter, resolve: resolve),
          defaultValue: nil,
          isFlagsBitfield: false, field: field)
      case .conditional(let flagsField, let bit, let wrapped):
        guard bitfieldNames.contains(flagsField) else {
          throw GeneratorError.missingFlagsField(
            combinator: combinator, field: field.tlName, flagsField: flagsField)
        }
        let flagsName = Naming.camelCase(flagsField)
        let attribute = "@TLConditional(\"\(flagsName)\", bit: \(bit))"
        if let wrapped {
          let type = try swiftType(
            for: wrapped, in: combinator, genericParameter: genericParameter, resolve: resolve)
          return EmittedProperty(
            attribute: combined(attribute, bareAttribute),
            name: name, type: "\(type)?", defaultValue: "nil",
            isFlagsBitfield: false, field: field)
        }
        // `flags.N?true`: the bit itself is the value.
        return EmittedProperty(
          attribute: attribute,
          name: name, type: "Bool", defaultValue: "false",
          isFlagsBitfield: false, field: field)
      }
    }
  }

  // MARK: - @TLObject structs (constructors and methods)

  /// How the `@TLObject` struct for a combinator is declared.
  @_spi(GeneratorInternals) public struct ObjectStructShape {
    /// `@TLObject(id:)` argument list past the id, e.g.
    /// `, returning: TL.Auth.SentCodeType.self` for plain RPC methods.
    @_spi(GeneratorInternals) public var attributeSuffix = ""
    /// Generic parameter clause, conformances and extra leading members for
    /// the generic `invokeWith…` wrappers.
    @_spi(GeneratorInternals) public var genericClause = ""
    @_spi(GeneratorInternals) public var conformances = "Equatable, Sendable"
    @_spi(GeneratorInternals) public var leadingMembers: [DeclSyntax] = []

    @_spi(GeneratorInternals) public init(
      attributeSuffix: String = "", genericClause: String = "",
      conformances: String = "Equatable, Sendable", leadingMembers: [DeclSyntax] = []
    ) {
      self.attributeSuffix = attributeSuffix
      self.genericClause = genericClause
      self.conformances = conformances
      self.leadingMembers = leadingMembers
    }
  }

  /// The `@TLObject(id:)` struct for a constructor or a method. Only the
  /// properties are laid out here; the initializer and `==` come from the macros.
  @_spi(GeneratorInternals) public func objectStructDecl(
    tlDeclaration: String,
    constructorID: UInt32,
    swiftName: SwiftName,
    fields: [TLField],
    combinator: String,
    visibility: String,
    shape: ObjectStructShape = ObjectStructShape(),
    resolve: TypeResolver? = nil
  ) throws -> DeclSyntax {
    let properties = try emittedProperties(of: fields, in: combinator, resolve: resolve)
    // Raw bits arrive off the wire but are recomputed on encode, so an `Equatable`
    // struct with a bitfield needs the flags-ignoring `==`.
    let flagsEquatable =
      properties.contains(where: \.isFlagsBitfield) && shape.conformances.contains("Equatable")
      ? "\n@TLFlagsEquatable" : ""

    let structDecl = try StructDeclSyntax(
      """
      /// TL: `\(raw: tlDeclaration)`
      @TLObject(id: \(raw: Naming.hexLiteral(constructorID))\(raw: shape.attributeSuffix))\(raw: flagsEquatable)
      \(raw: visibility) struct \(raw: swiftName.local)\(raw: shape.genericClause): \(raw: shape.conformances)
      """
    ) {
      for member in shape.leadingMembers {
        member
      }
      for property in properties {
        let attribute = property.attribute.map { "\($0) " } ?? ""
        let defaultSuffix = property.defaultValue.map { " = \($0)" } ?? ""
        DeclSyntax(
          "\(raw: attribute)\(raw: visibility) var \(raw: property.name): \(raw: property.type)\(raw: defaultSuffix)"
        )
      }
    }
    return DeclSyntax(structDecl)
  }

  /// The shape of a generic `invokeWith…` wrapper: the conformance is declared at
  /// the site, since attribute arguments cannot name the generic parameter.
  func genericFunctionShape(_ method: Method, visibility: String) throws -> ObjectStructShape {
    let returnType: String
    if case .genericQuery = method.returnType {
      returnType = "Query.ReturnType"
    } else {
      returnType = try swiftType(for: method.returnType, in: method.tlName)
    }
    // No `Equatable`: a generic wrapper's query is opaque and never compared.
    return ObjectStructShape(
      genericClause: "<Query: TLFunction>",
      conformances: "TLFunction, Sendable",
      leadingMembers: [
        DeclSyntax("\(raw: visibility) typealias ReturnType = \(raw: returnType)")
      ]
    )
  }

  // MARK: - Type enums

  /// The `@TLType` wrapper enum for a multi-constructor TL type: one case
  /// per constructor, each carrying the constructor's struct.
  func typeEnumDecl(_ type: TypeDefinition, visibility: String) throws -> DeclSyntax {
    let enumDecl = try EnumDeclSyntax(
      """
      /// The TL type `\(raw: type.tlName)` (\(raw: String(type.constructors.count)) constructors).
      @TLType
      \(raw: visibility) indirect enum \(raw: type.swiftEnumName!.local): Equatable, Sendable
      """
    ) {
      for constructor in type.constructors {
        DeclSyntax(
          """
          /// `\(raw: constructor.tlDeclaration)`
          case \(raw: constructor.caseName)(\(raw: constructor.swiftName.qualified))
          """
        )
      }
    }
    return DeclSyntax(enumDecl)
  }
}

extension TLField.Kind {
  static func == (lhs: Self, rhs: TLValueType) -> Bool {
    if case .plain(let value) = lhs { return value == rhs }
    return false
  }
}
