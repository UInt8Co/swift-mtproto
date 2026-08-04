#if canImport(FoundationNetworking)
  // Linux: URLSession lives in FoundationNetworking; everything else the
  // loader touches (Data, URL) comes from FoundationEssentials.
  import FoundationEssentials
  import FoundationNetworking
#else
  import Foundation
#endif

/// Loads the schema JSON from an `https://` URL, a `file://` URL, or a plain
/// filesystem path.
enum SchemaLoader {
  struct LoadError: Error, CustomStringConvertible {
    var description: String
  }

  static func load(from urlString: String) async throws -> Data {
    guard let url = URL(string: urlString), url.scheme != nil else {
      // Not a URL — treat it as a local path.
      return try Data(contentsOf: URL(fileURLWithPath: urlString))
    }
    if url.isFileURL {
      return try Data(contentsOf: url)
    }
    let (data, response) = try await download(url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw LoadError(description: "downloading \(url) failed with HTTP status \(http.statusCode)")
    }
    return data
  }

  /// Reads a local UTF-8 text file — the method manifest, which is always on
  /// disk rather than behind a URL.
  static func readText(at path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let text = String(data: data, encoding: .utf8) else {
      throw LoadError(description: "\(path) is not valid UTF-8")
    }
    return text
  }

  /// `URLSession.dataTask` wrapped in a continuation: the async
  /// `data(from:)` overloads are not consistently available with
  /// `FoundationNetworking` on Linux.
  private static func download(_ url: URL) async throws -> (Data, URLResponse) {
    try await withCheckedThrowingContinuation { continuation in
      URLSession.shared.dataTask(with: url) { data, response, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, let response {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(
            throwing: LoadError(description: "downloading \(url) returned no data"))
        }
      }.resume()
    }
  }
}
