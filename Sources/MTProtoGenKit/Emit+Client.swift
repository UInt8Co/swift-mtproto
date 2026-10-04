import SwiftSyntax
import SwiftSyntaxBuilder

/// Emission of the RPC client: a `TLClient` wrapping a user-provided
/// transport, with every schema method exposed as an `async` function,
/// grouped by TL namespace (`client.auth.sendCode(…)`).
extension ResolvedSchema {
  /// `Client/TLClient.swift` — the transport protocol and the client object.
  func clientCoreFile(visibility: String, extraImports: [String] = []) throws -> GeneratedFile {
    let transport = DeclSyntax(
      """
      /// Transport used by `TLClient`: delivers one serialized TL function
      /// call to the peer and returns the raw serialized reply body
      /// (the boxed result of that function).
      \(raw: visibility) protocol TLClientTransport: Sendable {
        func send(_ requestBody: Data) async throws -> Data
      }
      """
    )
    let client = try ClassDeclSyntax(
      """
      /// A Telegram RPC client: wraps a `TLClientTransport` and exposes every
      /// schema method as an `async` function, grouped by TL namespace
      /// (e.g. `client.auth.sendCode(…)`).
      \(raw: visibility) final class TLClient: Sendable
      """
    ) {
      DeclSyntax("\(raw: visibility) let transport: any TLClientTransport")
      DeclSyntax(
        """
        \(raw: visibility) init(transport: any TLClientTransport) {
          self.transport = transport
        }
        """
      )
      DeclSyntax(
        """
        /// Invokes a TL function and decodes its boxed result.
        \(raw: visibility) func invoke<Function: TLFunction>(_ function: Function) async throws -> Function.ReturnType {
          let replyBody = try await transport.send(function.tlSerialized())
          return try Function.ReturnType(tlData: replyBody)
        }
        """
      )
    }
    return GeneratedFile(
      path: "Client/TLClient.swift",
      contents: SwiftFile.render([transport, DeclSyntax(client)], extraImports: extraImports))
  }

  /// `Client/TLClient+<Namespace>.swift` — one namespace accessor struct
  /// (`client.auth`) with an async function per method. The global namespace
  /// (the generic `invokeWith…` wrappers) goes directly onto `TLClient` in
  /// `Client/TLClient+Methods.swift`.
  func clientNamespaceFile(
    namespace: String, methods: [Method], visibility: String, extraImports: [String] = []
  ) throws -> GeneratedFile {
    guard !namespace.isEmpty else {
      let extensionDecl = try ExtensionDeclSyntax("extension TLClient") {
        for method in methods {
          try clientMethodDecl(method, visibility: visibility, callee: "")
        }
      }
      return GeneratedFile(
        path: "Client/TLClient+Methods.swift",
        contents: SwiftFile.render([DeclSyntax(extensionDecl)], extraImports: extraImports))
    }

    // `AuthMethods` rather than `Auth`: a nested `Auth` would shadow the
    // top-level `TL.Auth` namespace inside the struct's own body.
    let namespaceEnum = Naming.namespaceEnumName(namespace)
    let groupName = "\(namespaceEnum)Methods"
    let accessorName = Naming.escaped(Naming.camelCase(namespace))
    let extensionDecl = try ExtensionDeclSyntax("extension TLClient") {
      DeclSyntax(
        """
        /// The `\(raw: namespace).*` methods.
        \(raw: visibility) var \(raw: accessorName): \(raw: groupName) { \(raw: groupName)(client: self) }
        """
      )
      try StructDeclSyntax(
        """
        /// The `\(raw: namespace).*` methods of a `TLClient`.
        \(raw: visibility) struct \(raw: groupName): Sendable
        """
      ) {
        DeclSyntax("\(raw: visibility) let client: TLClient")
        DeclSyntax(
          """
          \(raw: visibility) init(client: TLClient) {
            self.client = client
          }
          """
        )
        for method in methods {
          try clientMethodDecl(method, visibility: visibility, callee: "client.")
        }
      }
    }
    return GeneratedFile(
      path: "Client/TLClient+\(namespaceEnum).swift",
      contents: SwiftFile.render([DeclSyntax(extensionDecl)], extraImports: extraImports))
  }

  /// One async client method: builds the request struct from expanded
  /// parameters and invokes it.
  private func clientMethodDecl(
    _ method: Method, visibility: String, callee: String
  ) throws -> FunctionDeclSyntax {
    let properties = try emittedProperties(of: method.fields, in: method.tlName)
    let parameters = properties.filter { !$0.isFlagsBitfield }

    let parameterList = parameters
      .map { property in
        let defaultSuffix = property.defaultValue.map { " = \($0)" } ?? ""
        return "\(property.name): \(property.type)\(defaultSuffix)"
      }
      .joined(separator: ", ")
    let argumentList = parameters
      .map { "\(Naming.argumentLabel($0.name)): \($0.name)" }
      .joined(separator: ", ")

    let genericClause = method.isGeneric ? "<Query: TLFunction>" : ""
    let returnType: String
    if case .genericQuery = method.returnType {
      returnType = "Query.ReturnType"
    } else {
      returnType = try swiftType(for: method.returnType, in: method.tlName)
    }

    return try FunctionDeclSyntax(
      """
      /// TL: `\(raw: method.tlDeclaration)`
      \(raw: visibility) func \(raw: method.swiftMethodName)\(raw: genericClause)(\(raw: parameterList)) async throws -> \(raw: returnType)
      """
    ) {
      ExprSyntax(
        "try await \(raw: callee)invoke(\(raw: method.swiftName.qualified)(\(raw: argumentList)))")
    }
  }
}
