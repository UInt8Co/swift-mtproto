import MTProtoGenKit

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Writes generated files under the output directory.
///
/// The generator owns the `Types/`, `Methods/`, `Client/` and `Support/`
/// subdirectories — and, in a split run, every module directory: they are
/// replaced wholesale, so a declaration dropped from the schema leaves no stale
/// file behind. Anything else in the output directory is left untouched.
enum OutputWriter {
  static let managedSubdirectories = ["Types", "Methods", "Client", "Support"]

  static func write(_ files: [GeneratedFile], to outputDirectory: URL) throws {
    try replace(managedSubdirectories, in: outputDirectory)
    try write(files, relativeTo: outputDirectory)
  }

  /// Writes a split generation run: one directory per module, plus the
  /// `modules.json` manifest build systems declare their targets from.
  ///
  /// The module set follows the schema, so the *previous* run's directories are
  /// removed too — a module that no longer exists must not linger.
  static func write(_ package: GeneratedPackage, to outputDirectory: URL) throws {
    let manifest = outputDirectory.appendingPathComponent(GeneratedPackage.manifestFileName)
    var stale = managedSubdirectories
    if let data = try? Data(contentsOf: manifest),
      let previous = try? JSONDecoder().decode(PreviousManifest.self, from: data)
    {
      stale += previous.modules.map(\.directory)
    }
    try replace(stale + package.modules.map(\.directory), in: outputDirectory)

    for module in package.modules {
      try write(module.files, relativeTo: outputDirectory, under: module.directory)
    }
    try Data(package.manifestJSON().utf8).write(to: manifest)
  }

  /// Only the directory list is read back from a previous manifest.
  private struct PreviousManifest: Decodable {
    struct Module: Decodable { var directory: String }
    var modules: [Module]
  }

  private static func replace(_ subdirectories: [String], in outputDirectory: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for subdirectory in Set(subdirectories) {
      let directory = outputDirectory.appendingPathComponent(subdirectory, isDirectory: true)
      if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
      }
    }
  }

  private static func write(
    _ files: [GeneratedFile], relativeTo outputDirectory: URL, under subdirectory: String = ""
  ) throws {
    let fileManager = FileManager.default
    let root =
      subdirectory.isEmpty
      ? outputDirectory
      : outputDirectory.appendingPathComponent(subdirectory, isDirectory: true)
    for file in files {
      let destination = root.appendingPathComponent(file.path)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(file.contents.utf8).write(to: destination)
    }
  }
}
