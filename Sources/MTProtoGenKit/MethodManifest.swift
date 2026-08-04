/// A newline-delimited list of TL method names, for a generation run's
/// ``GeneratorOptions/selectedMethods``. See <doc:SelectingMethods>.
///
/// ```text
/// # The methods this build needs.
/// auth.sendCode
/// messages.sendMessage    # inline comments work too
/// ```
public enum MethodManifest {
  /// The method names in `text`, with `#` comments and blank lines ignored.
  ///
  /// Duplicates collapse. Throws
  /// ``GeneratorError/invalidMethodManifest(line:reason:)`` on a line that
  /// cannot be a TL method name, and on a manifest that selects nothing —
  /// which would silently generate an empty schema.
  public static func parse(_ text: String) throws -> Set<String> {
    var methods: Set<String> = []
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      let line = rawLine.prefix { $0 != "#" }.trimmingASCIIWhitespace
      guard !line.isEmpty else { continue }
      guard line.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else {
        throw GeneratorError.invalidMethodManifest(
          line: index + 1, reason: "'\(line)' is not a TL method name")
      }
      guard !line.hasPrefix("."), !line.hasSuffix("."), !line.contains("..") else {
        throw GeneratorError.invalidMethodManifest(
          line: index + 1, reason: "'\(line)' has an empty namespace or member")
      }
      methods.insert(String(line))
    }
    guard !methods.isEmpty else {
      throw GeneratorError.invalidMethodManifest(
        line: 0, reason: "the manifest names no methods; omit it to generate every method")
    }
    return methods
  }
}

extension StringProtocol {
  /// The slice without leading or trailing ASCII spaces and tabs.
  fileprivate var trimmingASCIIWhitespace: Self.SubSequence {
    let body = drop { $0 == " " || $0 == "\t" || $0 == "\r" }
    guard let end = body.lastIndex(where: { $0 != " " && $0 != "\t" && $0 != "\r" }) else {
      return body[body.startIndex..<body.startIndex]
    }
    return body[body.startIndex...end]
  }
}
