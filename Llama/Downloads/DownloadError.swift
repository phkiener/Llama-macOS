import Foundation

/// Describes errors that can occur before a model download begins.
enum DownloadError: Error, LocalizedError {
  case notCompatible(reason: String)
  case notEnoughDiskSpace(required: String, available: String)

  var errorDescription: String? {
    switch self {
    case .notCompatible:
      return "Model Not Compatible"
    case .notEnoughDiskSpace:
      return "Not Enough Disk Space"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .notCompatible(let reason):
      // `reason` is the menu row's standalone label ("Requires a Mac with
      // 32 GB+ of memory"), so it goes in as its own sentence rather than
      // after "This model". One label starts lowercase ("requires models
      // with ≥4k context"), hence the capitalized first letter.
      let sentence = reason.prefix(1).uppercased() + reason.dropFirst()
      return "\(sentence). Choose a smaller model or upgrade your system memory."
    case .notEnoughDiskSpace(let required, let available):
      return
        "This model requires \(required) of free space, but only \(available) is available. Please free up some space."
    }
  }
}
