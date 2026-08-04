import Testing

@_spi(GeneratorInternals) @testable import MTProtoGenKit

@Suite("Naming")
struct NamingTests {
  @Test func camelCase() {
    #expect(Naming.camelCase("first_name") == "firstName")
    #expect(Naming.camelCase("md5_checksum") == "md5Checksum")
    #expect(Naming.camelCase("flags2") == "flags2")
    #expect(Naming.camelCase("id") == "id")
  }

  @Test func flattening() {
    #expect(Naming.flattened("auth.sentCode") == "AuthSentCode")
    #expect(Naming.flattened("inputPeerEmpty") == "InputPeerEmpty")
    #expect(Naming.namespaceEnumName("auth") == "Auth")
    #expect(Naming.caseName("auth.sentCodeSuccess") == "authSentCodeSuccess")
    #expect(Naming.caseName("sentCodeSuccess") == "sentCodeSuccess")
  }

  @Test func keywordEscaping() {
    #expect(Naming.propertyName("default") == "`default`")
    #expect(Naming.propertyName("static") == "`static`")
    #expect(Naming.propertyName("self") == "self_")
    #expect(Naming.propertyName("public_key") == "publicKey")
    #expect(Naming.propertyName("id") == "id")
  }

  @Test func namespaces() {
    #expect(Naming.namespace(of: "auth.sendCode") == "auth")
    #expect(Naming.namespace(of: "initConnection") == nil)
    #expect(Naming.localName(of: "auth.sendCode") == "sendCode")
    #expect(Naming.localName(of: "initConnection") == "initConnection")
  }

  @Test func hexLiterals() {
    #expect(Naming.hexLiteral(0x05162463) == "0x05162463")
    #expect(Naming.hexLiteral(0xFFFF_FFFF) == "0xffffffff")
    #expect(Naming.hexLiteral(1) == "0x00000001")
  }
}
