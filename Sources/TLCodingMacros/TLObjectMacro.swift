import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implementation of `@TLObject`: generates MTProto (TL) binary
/// encoding/decoding for a struct (single TL constructor) or an enum
/// (one TL constructor per case).
public struct TLObjectMacro: ExtensionMacro, MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      return try expandStruct(structDecl, node: node, type: type, protocols: protocols)
    }
    if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      return try expandEnum(enumDecl, node: node, type: type, protocols: protocols)
    }
    throw macroError(node, "@TLObject can only be attached to a struct or an enum", id: "wrongDecl")
  }

  /// The memberwise initializer, without the `@TLFlags` bitfields (recomputed on
  /// encode). Skipped when the struct declares an initializer of its own.
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }
    // Validate the TL fields so a malformed struct reports its real error here
    // too, rather than a confusing "missing initializer" downstream.
    var properties = try collectProperties(structDecl)
    try validateAndResolve(&properties)
    return synthesizedMembers(structDecl)
  }
}

// MARK: - Synthesized members

/// The access-level keyword generated members carry: `public`/`package` mirror
/// the struct, everything else is left implicit (the type's own access level
/// already caps it).
private func memberVisibility(_ structDecl: StructDeclSyntax) -> String {
  for modifier in structDecl.modifiers {
    switch modifier.name.tokenKind {
    case .keyword(.public), .keyword(.open): return "public "
    case .keyword(.package): return "package "
    default: continue
    }
  }
  return ""
}

private func declaresInitializer(_ structDecl: StructDeclSyntax) -> Bool {
  structDecl.memberBlock.members.contains { $0.decl.is(InitializerDeclSyntax.self) }
}

private func declaresEqualityOperator(_ structDecl: StructDeclSyntax) -> Bool {
  structDecl.memberBlock.members.contains { member in
    guard let function = member.decl.as(FunctionDeclSyntax.self) else { return false }
    return function.name.text == "==" && hasModifier(function, .static)
  }
}

/// One stored property as the synthesized members see it, `@TLOmit`ted ones
/// included — unlike ``TLProperty``, which models TL fields.
private struct StoredProperty {
  var name: String
  /// Type exactly as written, including any `?`.
  var type: String
  /// Default the declaration itself gives, else `nil` / `false` for a field
  /// shape the wire format makes optional.
  var defaultValue: String?
  var isFlagsField: Bool
  /// A `let` with an initializer is already fixed and cannot be assigned.
  var isAssignable: Bool
}

private func collectStoredProperties(_ structDecl: StructDeclSyntax) -> [StoredProperty] {
  var result: [StoredProperty] = []
  for member in structDecl.memberBlock.members {
    guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
    if hasModifier(varDecl, .static) || hasModifier(varDecl, .lazy) { continue }
    guard varDecl.bindings.allSatisfy(isStoredBinding) else { continue }
    guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first,
      let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
      let annotation = binding.typeAnnotation
    else { continue }
    let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)
    let written = annotation.type.trimmed
    let (_, isOptional) = unwrapOptional(written)
    let isPresenceBool =
      attribute(named: "TLConditional", in: varDecl.attributes) != nil
      && !isOptional && written.trimmedDescription == "Bool"
    let declared = binding.initializer?.value.trimmedDescription
    result.append(
      StoredProperty(
        name: pattern.identifier.text,
        type: written.description,
        defaultValue: declared ?? (isOptional ? "nil" : (isPresenceBool ? "false" : nil)),
        isFlagsField: attribute(named: "TLFlags", in: varDecl.attributes) != nil,
        isAssignable: !(isLet && binding.initializer != nil)))
  }
  return result
}

private func synthesizedMembers(_ structDecl: StructDeclSyntax) -> [DeclSyntax] {
  guard !declaresInitializer(structDecl) else { return [] }
  let visibility = memberVisibility(structDecl)
  // Flags bitfields are recomputed from the conditional fields on encode, so
  // they are not initializer parameters.
  let assignable = collectStoredProperties(structDecl)
    .filter { !$0.isFlagsField && $0.isAssignable }
  let parameters = assignable
    .map { "\($0.name): \($0.type)\($0.defaultValue.map { " = \($0)" } ?? "")" }
    .joined(separator: ", ")
  let assignments = assignable
    .map { "self.\($0.name) = \($0.name)" }
    .joined(separator: "\n  ")
  return [
    """
    \(raw: visibility)init(\(raw: parameters)) {
      \(raw: assignments)
    }
    """
  ]
}

/// Implementation of `@TLFlagsEquatable`: the `==` that compares the logical
/// fields and skips the `@TLFlags` bitfields.
///
/// Deliberately not part of `@TLObject`: a macro declaring `named(==)` makes the
/// compiler derive the `Equatable` witness and silently ignore a hand-written
/// operator, so the effect stays opt-in.
public struct TLFlagsEquatableMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw macroError(node, "@TLFlagsEquatable can only be attached to a struct", id: "wrongDecl")
    }
    let stored = collectStoredProperties(structDecl)
    guard stored.contains(where: \.isFlagsField) else {
      throw macroError(
        node,
        "@TLFlagsEquatable needs a @TLFlags property; without a bitfield the compiler's own memberwise '==' is already correct",
        id: "noFlags")
    }
    guard !declaresEqualityOperator(structDecl) else {
      throw macroError(
        node,
        "@TLFlagsEquatable generates '=='; remove the hand-written one (it would not be used as the Equatable witness)",
        id: "duplicateEquality")
    }
    let compared = stored.filter { !$0.isFlagsField }
    let comparisons =
      compared.isEmpty
      ? "true"
      : compared.map { "lhs.\($0.name) == rhs.\($0.name)" }.joined(separator: "\n    && ")
    return [
      """
      /// Equality over the logical fields, ignoring the raw `@TLFlags`
      /// bitfields (which are recomputed on encode).
      \(raw: memberVisibility(structDecl))static func == (lhs: Self, rhs: Self) -> Bool {
        \(raw: comparisons)
      }
      """
    ]
  }
}

// MARK: - Macro arguments

private struct TLObjectArguments {
  var explicitID: UInt32?
  var schema: String?
  /// The `ReturnType` of a TL function, from `returning: SomeType.self`.
  var returning: String?
}

private func parseObjectArguments(_ node: AttributeSyntax) throws -> TLObjectArguments {
  var result = TLObjectArguments()
  guard let arguments = attributeArguments(node) else { return result }
  for argument in arguments {
    switch argument.label?.text {
    case "id":
      guard let value = parseIntegerLiteral(argument.expression, as: UInt32.self) else {
        throw macroError(argument, "'id' must be a 32-bit unsigned integer literal", id: "badID")
      }
      result.explicitID = value
    case "schema":
      guard let value = parseStringLiteral(argument.expression) else {
        throw macroError(argument, "'schema' must be a static string literal", id: "badSchema")
      }
      result.schema = value
    case "returning":
      guard let member = argument.expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.tokenKind == .keyword(.self),
        let base = member.base
      else {
        throw macroError(
          argument, "'returning' must be a metatype literal like 'SomeType.self'",
          id: "badReturning")
      }
      result.returning = base.trimmedDescription
    default:
      throw macroError(argument, "unknown argument for @TLObject", id: "badArgument")
    }
  }
  return result
}

// MARK: - Struct expansion

/// One serializable stored property of a `@TLObject` struct.
private struct TLProperty {
  var name: String
  /// The non-optional type, as written (e.g. `Int32`, `[User]`).
  var typeText: String
  var typeSyntax: TypeSyntax
  var isOptional: Bool
  var isBare: Bool
  var isBareElement: Bool
  var isFlagsField: Bool
  var conditionalBit: Int?
  /// Resolved name of the `@TLFlags` property this conditional belongs to.
  var conditionalFlagsField: String?
  /// `flags.N?true`: a non-optional `Bool` whose value lives in the bit.
  var isPresenceBool: Bool {
    conditionalBit != nil && !isOptional && typeText == "Bool"
  }
  var anchor: Syntax
}

private func flagsVariable(_ fieldName: String) -> String {
  "_tl_flags_\(fieldName)"
}

private func collectProperties(_ structDecl: StructDeclSyntax) throws -> [TLProperty] {
  var properties: [TLProperty] = []
  for member in structDecl.memberBlock.members {
    guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
    if hasModifier(varDecl, .static) { continue }
    if attribute(named: "TLOmit", in: varDecl.attributes) != nil { continue }
    if hasModifier(varDecl, .lazy) {
      throw macroError(
        varDecl, "lazy properties cannot be TL fields; mark with @TLOmit", id: "lazy")
    }
    guard varDecl.bindings.allSatisfy(isStoredBinding) else { continue }
    guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first else {
      throw macroError(varDecl, "declare each TL field as a separate property", id: "multiBinding")
    }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
      throw macroError(binding, "TL fields must be simple named properties", id: "pattern")
    }
    guard let annotation = binding.typeAnnotation else {
      throw macroError(binding, "TL fields need an explicit type annotation", id: "noType")
    }
    let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)
    if isLet && binding.initializer != nil {
      throw macroError(
        varDecl,
        "a 'let' with a default value cannot be decoded; use 'var' or mark it @TLOmit",
        id: "letDefault"
      )
    }

    let (wrappedType, isOptional) = unwrapOptional(annotation.type.trimmed)
    var property = TLProperty(
      name: pattern.identifier.text,
      typeText: wrappedType.trimmedDescription,
      typeSyntax: wrappedType,
      isOptional: isOptional,
      isBare: attribute(named: "TLBare", in: varDecl.attributes) != nil,
      isBareElement: attribute(named: "TLBareElements", in: varDecl.attributes) != nil,
      isFlagsField: attribute(named: "TLFlags", in: varDecl.attributes) != nil,
      conditionalBit: nil,
      conditionalFlagsField: nil,
      anchor: Syntax(varDecl)
    )

    if let conditional = attribute(named: "TLConditional", in: varDecl.attributes) {
      guard let arguments = attributeArguments(conditional) else {
        throw macroError(conditional, "@TLConditional requires a 'bit' argument", id: "noBit")
      }
      for argument in arguments {
        switch argument.label?.text {
        case "bit":
          guard let bit = parseIntegerLiteral(argument.expression, as: Int.self),
            (0...31).contains(bit)
          else {
            throw macroError(argument, "'bit' must be an integer literal in 0...31", id: "badBit")
          }
          property.conditionalBit = bit
        case nil:
          guard let field = parseStringLiteral(argument.expression) else {
            throw macroError(
              argument, "the flags field reference must be a string literal", id: "badFlagsRef")
          }
          property.conditionalFlagsField = field
        default:
          throw macroError(argument, "unknown argument for @TLConditional", id: "badArgument")
        }
      }
      guard property.conditionalBit != nil else {
        throw macroError(conditional, "@TLConditional requires a 'bit' argument", id: "noBit")
      }
    }

    properties.append(property)
  }
  return properties
}

private func validateAndResolve(_ properties: inout [TLProperty]) throws {
  let flagsFields = properties.enumerated().filter { $0.element.isFlagsField }
  for (_, field) in flagsFields {
    guard field.typeText == "UInt32", !field.isOptional else {
      throw macroError(field.anchor, "@TLFlags properties must have type UInt32", id: "flagsType")
    }
  }

  for index in properties.indices {
    var property = properties[index]
    defer { properties[index] = property }

    if property.isFlagsField {
      if property.conditionalBit != nil {
        throw macroError(
          property.anchor, "a property cannot be both @TLFlags and @TLConditional",
          id: "flagsConditional")
      }
      continue
    }

    if property.conditionalBit != nil {
      // Resolve which flags field the bit lives in.
      let resolvedField: (offset: Int, element: TLProperty)?
      if let explicit = property.conditionalFlagsField {
        resolvedField = flagsFields.first { $0.element.name == explicit }
        guard resolvedField != nil else {
          throw macroError(
            property.anchor, "no @TLFlags property named '\(explicit)'", id: "unknownFlags")
        }
      } else if flagsFields.count == 1 {
        resolvedField = flagsFields[0]
      } else if flagsFields.isEmpty {
        throw macroError(
          property.anchor, "@TLConditional requires a @TLFlags property in the struct",
          id: "noFlags")
      } else {
        throw macroError(
          property.anchor,
          "multiple @TLFlags properties; name one explicitly, e.g. @TLConditional(\"flags\", bit: ...)",
          id: "ambiguousFlags"
        )
      }
      guard let resolved = resolvedField else { fatalError("unreachable") }
      guard resolved.offset < index else {
        throw macroError(
          property.anchor,
          "conditional fields must be declared after their @TLFlags property (wire order)",
          id: "flagsOrder"
        )
      }
      property.conditionalFlagsField = resolved.element.name

      if !property.isOptional && property.typeText != "Bool" {
        throw macroError(
          property.anchor,
          "@TLConditional fields must be Optional, or Bool for a flags.N?true presence bit",
          id: "conditionalType"
        )
      }
    } else if property.isOptional {
      throw macroError(
        property.anchor,
        "Optional TL fields must be marked @TLConditional(bit:)",
        id: "optionalNotConditional"
      )
    }
  }
}

private func autoSchema(structName: String, properties: [TLProperty]) throws -> String {
  var fields: [String] = []
  for property in properties {
    let fieldName = SchemaBuilder.snakeCase(property.name)
    if property.isFlagsField {
      fields.append("\(fieldName):#")
      continue
    }
    if let bit = property.conditionalBit, let flagsField = property.conditionalFlagsField {
      let flagsName = SchemaBuilder.snakeCase(flagsField)
      if property.isPresenceBool {
        fields.append("\(fieldName):\(flagsName).\(bit)?true")
        continue
      }
      guard let tlType = SchemaBuilder.tlTypeName(property.typeSyntax) else {
        throw cannotDeriveType(property)
      }
      fields.append("\(fieldName):\(flagsName).\(bit)?\(tlType)")
      continue
    }
    guard let tlType = SchemaBuilder.tlTypeName(property.typeSyntax) else {
      throw cannotDeriveType(property)
    }
    fields.append("\(fieldName):\(property.isBare ? "%" : "")\(tlType)")
  }
  let combinator = SchemaBuilder.lowercasedFirst(structName)
  let fieldList = fields.isEmpty ? "" : " " + fields.joined(separator: " ")
  return "\(combinator)\(fieldList) = \(structName)"
}

private func cannotDeriveType(_ property: TLProperty) -> DiagnosticsError {
  macroError(
    property.anchor,
    "cannot derive a TL type for '\(property.typeText)'; provide @TLObject(id:) or @TLObject(schema:) explicitly",
    id: "underivableType"
  )
}

/// The `Array`/value encode method for a field, selecting among the four
/// combinations of bare vector (`@TLBare`) and bare elements
/// (`@TLBareElements`). `@TLBareElements` is a vector-only attribute.
private func encodeMethod(for property: TLProperty) -> String {
  switch (property.isBare, property.isBareElement) {
  case (false, false): return "tlEncode"
  case (true, false): return "tlEncodeBare"
  case (false, true): return "tlEncodeBareElements"
  case (true, true): return "tlEncodeFullyBare"
  }
}

/// The decode initializer label mirroring ``encodeMethod(for:)``.
private func decodeLabel(for property: TLProperty) -> String {
  switch (property.isBare, property.isBareElement) {
  case (false, false): return "tlFrom"
  case (true, false): return "tlBareFrom"
  case (false, true): return "tlBareElementsFrom"
  case (true, true): return "tlFullyBareFrom"
  }
}

private func expandStruct(
  _ structDecl: StructDeclSyntax,
  node: AttributeSyntax,
  type: some TypeSyntaxProtocol,
  protocols: [TypeSyntax]
) throws -> [ExtensionDeclSyntax] {
  let arguments = try parseObjectArguments(node)
  var properties = try collectProperties(structDecl)
  try validateAndResolve(&properties)

  let constructorID: UInt32
  if let explicit = arguments.explicitID {
    constructorID = explicit
  } else if let schema = arguments.schema {
    constructorID = SchemaBuilder.constructorID(forDeclaration: schema)
  } else {
    let derived = try autoSchema(structName: structDecl.name.text, properties: properties)
    constructorID = SchemaBuilder.constructorID(forDeclaration: derived)
  }

  // --- encode ---
  var encodeLines: [String] = []
  let flagsFieldNames = properties.filter(\.isFlagsField).map(\.name)
  for fieldName in flagsFieldNames {
    let isReferenced = properties.contains { $0.conditionalFlagsField == fieldName }
    let keyword = isReferenced ? "var" : "let"
    encodeLines.append("\(keyword) \(flagsVariable(fieldName)): UInt32 = 0")
  }
  for property in properties {
    guard let bit = property.conditionalBit, let flagsField = property.conditionalFlagsField else {
      continue
    }
    if property.isPresenceBool {
      encodeLines.append(
        "if self.\(property.name) { \(flagsVariable(flagsField)) |= (1 << \(bit)) }")
    } else {
      encodeLines.append(
        "if self.\(property.name) != nil { \(flagsVariable(flagsField)) |= (1 << \(bit)) }")
    }
  }
  for property in properties {
    let encodeCall = encodeMethod(for: property)
    if property.isFlagsField {
      encodeLines.append("writer.writeUInt32(\(flagsVariable(property.name)))")
    } else if property.isPresenceBool {
      continue  // the bit carries the value; nothing on the wire
    } else if property.conditionalBit != nil {
      encodeLines.append(
        "if let _value = self.\(property.name) { _value.\(encodeCall)(to: &writer) }")
    } else {
      encodeLines.append("self.\(property.name).\(encodeCall)(to: &writer)")
    }
  }

  // --- decode ---
  var decodeLines: [String] = []
  for property in properties {
    let initLabel = decodeLabel(for: property)
    if property.isFlagsField {
      decodeLines.append("let \(flagsVariable(property.name)) = try reader.readUInt32()")
      decodeLines.append("self.\(property.name) = \(flagsVariable(property.name))")
    } else if property.isPresenceBool {
      let flagsVar = flagsVariable(property.conditionalFlagsField!)
      decodeLines.append(
        "self.\(property.name) = (\(flagsVar) & (1 << \(property.conditionalBit!))) != 0")
    } else if let bit = property.conditionalBit {
      let flagsVar = flagsVariable(property.conditionalFlagsField!)
      decodeLines.append(
        """
        if (\(flagsVar) & (1 << \(bit))) != 0 {
            self.\(property.name) = try \(property.typeText)(\(initLabel): &reader)
        } else {
            self.\(property.name) = nil
        }
        """)
    } else {
      decodeLines.append("self.\(property.name) = try \(property.typeText)(\(initLabel): &reader)")
    }
  }

  let returningMember = arguments.returning.map {
    "\npublic typealias ReturnType = \($0)\n"
  }

  // A generic struct (an `invokeWithLayer`-style wrapper with an opaque
  // query) cannot be decoded statically: generate the encoder only, and
  // conform to `TLEncodable` (and `TLFunction`) but not
  // `TLConstructed`/`TLDecodable`.
  if structDecl.genericParameterClause != nil {
    guard arguments.explicitID != nil || arguments.schema != nil else {
      throw macroError(
        node,
        "a generic @TLObject struct needs an explicit 'id:' or 'schema:' (the TL declaration cannot be derived)",
        id: "genericAutoID"
      )
    }
    let clause = conformanceClause(protocols, excluding: ["TLConstructed", "TLDecodable"])
    let declaration: DeclSyntax = """
      extension \(type.trimmed)\(raw: clause) {
          \(raw: returningMember ?? "")
          public static var tlConstructorID: UInt32 { \(raw: formatHex(constructorID)) }

          public func tlEncode(to writer: inout TLWriter) {
              writer.writeUInt32(Self.tlConstructorID)
              tlEncodeBare(to: &writer)
          }

          public func tlEncodeBare(to writer: inout TLWriter) {
              \(raw: encodeLines.joined(separator: "\n    "))
          }
      }
      """
    guard let extensionDecl = declaration.as(ExtensionDeclSyntax.self) else {
      throw macroError(node, "internal error: failed to build extension", id: "internal")
    }
    return [extensionDecl]
  }

  let declaration: DeclSyntax = """
    extension \(type.trimmed)\(raw: conformanceClause(protocols)) {
        \(raw: returningMember ?? "")
        public static var tlConstructorID: UInt32 { \(raw: formatHex(constructorID)) }

        public func tlEncodeBare(to writer: inout TLWriter) {
            \(raw: encodeLines.joined(separator: "\n    "))
        }

        public init(tlBareFrom reader: inout TLReader) throws {
            \(raw: decodeLines.joined(separator: "\n    "))
        }
    }
    """
  guard let extensionDecl = declaration.as(ExtensionDeclSyntax.self) else {
    throw macroError(node, "internal error: failed to build extension", id: "internal")
  }
  return [extensionDecl]
}

// MARK: - Enum expansion

private struct TLCaseInfo {
  var name: String
  var parameters: [(label: String?, typeText: String)]
  var constructorID: UInt32
}

private func expandEnum(
  _ enumDecl: EnumDeclSyntax,
  node: AttributeSyntax,
  type: some TypeSyntaxProtocol,
  protocols: [TypeSyntax]
) throws -> [ExtensionDeclSyntax] {
  let arguments = try parseObjectArguments(node)
  if arguments.explicitID != nil || arguments.schema != nil {
    throw macroError(
      node,
      "an enum has one constructor per case; use @TLCase(id:)/@TLCase(schema:) on the cases instead",
      id: "enumArgs"
    )
  }
  if arguments.returning != nil {
    throw macroError(
      node, "'returning' applies to function structs, not enums", id: "enumReturning")
  }

  var cases: [TLCaseInfo] = []
  for member in enumDecl.memberBlock.members {
    guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }

    var explicitID: UInt32?
    var explicitSchema: String?
    if let caseAttribute = attribute(named: "TLCase", in: caseDecl.attributes) {
      guard let caseArguments = attributeArguments(caseAttribute) else {
        throw macroError(caseAttribute, "@TLCase requires 'id:' or 'schema:'", id: "emptyCase")
      }
      for argument in caseArguments {
        switch argument.label?.text {
        case "id":
          guard let value = parseIntegerLiteral(argument.expression, as: UInt32.self) else {
            throw macroError(
              argument, "'id' must be a 32-bit unsigned integer literal", id: "badID")
          }
          explicitID = value
        case "schema":
          guard let value = parseStringLiteral(argument.expression) else {
            throw macroError(argument, "'schema' must be a static string literal", id: "badSchema")
          }
          explicitSchema = value
        default:
          throw macroError(argument, "unknown argument for @TLCase", id: "badArgument")
        }
      }
      if caseDecl.elements.count > 1 {
        throw macroError(
          caseDecl, "@TLCase applies to a single case; split this declaration", id: "multiElement")
      }
    }

    for element in caseDecl.elements {
      var parameters: [(label: String?, typeText: String)] = []
      if let clause = element.parameterClause {
        for parameter in clause.parameters {
          let (wrapped, wasOptional) = unwrapOptional(parameter.type.trimmed)
          if wasOptional {
            throw macroError(
              parameter,
              "optional associated values are not supported; model conditional fields with a @TLObject struct payload",
              id: "optionalAssoc"
            )
          }
          var label = parameter.firstName?.text
          if label == "_" { label = nil }
          parameters.append((label: label, typeText: wrapped.trimmedDescription))
        }
      }

      let constructorID: UInt32
      if let explicitID {
        constructorID = explicitID
      } else if let explicitSchema {
        constructorID = SchemaBuilder.constructorID(forDeclaration: explicitSchema)
      } else {
        var fields: [String] = []
        if let clause = element.parameterClause {
          for parameter in clause.parameters {
            guard let label = parameter.firstName?.text, label != "_" else {
              throw macroError(
                parameter,
                "associated values need labels to derive a TL declaration; or use @TLCase(id:)",
                id: "unlabeledAssoc"
              )
            }
            guard let tlType = SchemaBuilder.tlTypeName(parameter.type) else {
              throw macroError(
                parameter,
                "cannot derive a TL type for '\(parameter.type.trimmedDescription)'; use @TLCase(id:) or @TLCase(schema:)",
                id: "underivableType"
              )
            }
            fields.append("\(SchemaBuilder.snakeCase(label)):\(tlType)")
          }
        }
        let fieldList = fields.isEmpty ? "" : " " + fields.joined(separator: " ")
        let declaration = "\(element.name.text)\(fieldList) = \(enumDecl.name.text)"
        constructorID = SchemaBuilder.constructorID(forDeclaration: declaration)
      }

      cases.append(
        TLCaseInfo(name: element.name.text, parameters: parameters, constructorID: constructorID))
    }
  }

  guard !cases.isEmpty else {
    throw macroError(node, "@TLObject enums must declare at least one case", id: "emptyEnum")
  }
  var seenIDs: Set<UInt32> = []
  for caseInfo in cases {
    guard seenIDs.insert(caseInfo.constructorID).inserted else {
      throw macroError(
        node,
        "duplicate constructor number \(formatHex(caseInfo.constructorID)) for case '\(caseInfo.name)'",
        id: "duplicateID"
      )
    }
  }

  let idList = cases.map { formatHex($0.constructorID) }.joined(separator: ", ")

  var idLines: [String] = []
  var encodeLines: [String] = []
  var decodeLines: [String] = []
  for caseInfo in cases {
    let hexID = formatHex(caseInfo.constructorID)
    idLines.append("case .\(caseInfo.name): return \(hexID)")

    if caseInfo.parameters.isEmpty {
      encodeLines.append(
        """
        case .\(caseInfo.name):
            writer.writeUInt32(\(hexID))
        """)
      decodeLines.append(
        """
        case \(hexID):
            self = .\(caseInfo.name)
        """)
    } else {
      let bindings = caseInfo.parameters.indices.map { "let _value\($0)" }.joined(separator: ", ")
      let writes = caseInfo.parameters.indices
        .map { "    _value\($0).tlEncode(to: &writer)" }
        .joined(separator: "\n")
      encodeLines.append(
        """
        case .\(caseInfo.name)(\(bindings)):
            writer.writeUInt32(\(hexID))
        \(writes)
        """)

      let reads = caseInfo.parameters
        .map { parameter -> String in
          let prefix = parameter.label.map { "\($0): " } ?? ""
          return "\(prefix)try \(parameter.typeText)(tlFrom: &reader)"
        }
        .joined(separator: ", ")
      decodeLines.append(
        """
        case \(hexID):
            self = .\(caseInfo.name)(\(reads))
        """)
    }
  }

  // Enums have one constructor per case, so they are never `TLConstructed`.
  let declaration: DeclSyntax = """
    extension \(type.trimmed)\(raw: conformanceClause(protocols, excluding: ["TLConstructed"])) {
        public static var tlConstructorIDs: [UInt32] { [\(raw: idList)] }

        public var tlConstructorID: UInt32 {
            switch self {
            \(raw: idLines.joined(separator: "\n        "))
            }
        }

        public func tlEncode(to writer: inout TLWriter) {
            switch self {
            \(raw: encodeLines.joined(separator: "\n        "))
            }
        }

        public init(tlFrom reader: inout TLReader) throws {
            let constructorID = try reader.readUInt32()
            switch constructorID {
            \(raw: decodeLines.joined(separator: "\n        "))
            default:
                throw TLError.unexpectedConstructor(found: constructorID, expected: Self.tlConstructorIDs)
            }
        }
    }
    """
  guard let extensionDecl = declaration.as(ExtensionDeclSyntax.self) else {
    throw macroError(node, "internal error: failed to build extension", id: "internal")
  }
  return [extensionDecl]
}
