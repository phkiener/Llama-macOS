import Foundation
import os.log

/// The remote model catalog.
///
/// Llama no longer ships a hard-coded catalog; curation lives on the web at
/// `llama.app`, which also publishes a JSON endpoint the app can
/// consume. We use it for a lightweight in-app "Discover" section — a handful of
/// featured families, up to two device-appropriate picks each — so a fresh
/// install can get a model running in a couple of clicks without first visiting
/// the website.
///
/// Each featured family shows every size this Mac can run, one row per size,
/// each resolved to the highest-precision quant that fits. "Full precision" is
/// whatever the catalog lists as the size's top build — Q8 for 16-bit families,
/// Q4 for QAT ones like Gemma 3 — and lower quants are strictly fallbacks. So a
/// row's quant is never a choice we made: a below-top quant means the top one
/// wouldn't run on this machine, nothing more. Which sizes exist and which
/// families are featured is the website's curation; the app only filters by
/// what fits (plus optional per-family and per-size memory caps, also declared
/// by the catalog).
///
/// The full browsing experience stays on the web; the app only ever reads the
/// `featured` slice.
enum Catalog {
  private static let logger = Logger(subsystem: Logging.subsystem, category: "Catalog")

  /// Published catalog endpoint. Same URL for dev and production builds — the
  /// catalog is environment-agnostic; only the install deeplink scheme differs.
  static let endpoint = URL(string: "https://llama.app/v1/catalog.json")!

  // MARK: - Wire format
  //
  // Mirrors the catalog's published shape: family → size → build. Only the
  // fields the app reads are decoded; everything else (publisher prose, etc.)
  // is the website's concern and is ignored here.

  /// A downloadable quant of a size — the same weights at a given quantization.
  /// Each build carries its own repo since quants sometimes live in different
  /// orgs (e.g. Q4 under the publisher, Q8 mirrored under ggml-org).
  struct Build: Decodable {
    let quant: String?
    let size: String?  // human label, e.g. "5.0 GB"
    let repo: String  // "{org}/{repo}"
  }

  /// A parameter tier within a family, e.g. "Gemma 4 E4B". The catalog's
  /// `name` is not decoded: rows are titled by the repo's id base, so the
  /// curated display name is the website's concern only.
  struct Size: Decodable {
    /// Whether this size supports image input. Absent → false.
    let vision: Bool?
    /// Memory cap for featuring, like `Family.maxMemGb` but for one size: on
    /// Macs with more RAM than this, the size is not suggested (e.g. the small
    /// Gemma 4 E-series on 32 GB+ Macs). Absent → the family's cap alone applies.
    let maxMemGb: UInt64?
    /// Whether the catalog marks this size as the suggested starting point for
    /// newcomers. The row gets a "Good first model" badge and is listed first.
    /// Absent → false.
    let goodFirstModel: Bool?
    let builds: [Build]
  }

  /// A named release line, e.g. "Gemma 4". Holds the shared metadata.
  struct Family: Decodable {
    let brand: String
    /// Whether the catalog flags this family for in-app highlighting. Absent → false.
    let featured: Bool?
    /// Memory cap for featuring: on Macs with more RAM than this, the family is
    /// not suggested even though it would fit. Lets the catalog mark a family as
    /// a low-memory pick (e.g. Gemma 3 on 8 GB Macs) without the app hardcoding
    /// curation. Absent → no cap.
    let maxMemGb: UInt64?
    let sizes: [Size]
  }
}
