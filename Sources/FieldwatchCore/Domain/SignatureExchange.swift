import Foundation

// Port of domain/SignatureExchange.kt. Signature packs (fieldwatch-signatures JSON) move between
// Android and macOS, so the JSON shape follows kotlinx (encodeDefaults, explicit nulls, unknown keys ignored).

/// Kotlin `IllegalArgumentException` thrown by pack parsing. `message` is the user-facing text.
public struct ExchangeError: Error, LocalizedError, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public struct SignaturePack: Codable, Hashable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var exportedAt: String
    public var appVersion: String
    public var catalogVersion: Int
    public var fleets: [Fleet]

    public static let FORMAT = "fieldwatch-signatures"
    public static let LEGACY_FORMAT = "spectre-signatures"
    public static let FORMAT_VERSION = 1

    public init(
        format: String = SignaturePack.FORMAT,
        formatVersion: Int = SignaturePack.FORMAT_VERSION,
        exportedAt: String = "",
        appVersion: String = "",
        catalogVersion: Int = 0,
        fleets: [Fleet] = []
    ) {
        self.format = format; self.formatVersion = formatVersion; self.exportedAt = exportedAt
        self.appVersion = appVersion; self.catalogVersion = catalogVersion; self.fleets = fleets
    }

    enum CodingKeys: String, CodingKey { case format, formatVersion, exportedAt, appVersion, catalogVersion, fleets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(.format, default: SignaturePack.FORMAT)
        formatVersion = try c.decode(.formatVersion, default: SignaturePack.FORMAT_VERSION)
        exportedAt = try c.decode(.exportedAt, default: "")
        appVersion = try c.decode(.appVersion, default: "")
        catalogVersion = try c.decode(.catalogVersion, default: 0)
        fleets = try c.decode(.fleets, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(catalogVersion, forKey: .catalogVersion)
        try c.encode(fleets, forKey: .fleets)
    }
}

public struct StockCatalogUpdateResult: Hashable, Sendable {
    public var alreadyLatest: Bool
    public var added: Int
    public var updated: Int
    public var catalogVersion: Int
    /// Decode maps dropped because this build does not know their source. Signatures still match.
    public var skippedDecode: Int
    public var error: String?

    public init(alreadyLatest: Bool = false, added: Int = 0, updated: Int = 0, catalogVersion: Int = 0,
                skippedDecode: Int = 0, error: String? = nil) {
        self.alreadyLatest = alreadyLatest; self.added = added; self.updated = updated
        self.catalogVersion = catalogVersion; self.skippedDecode = skippedDecode; self.error = error
    }
}

public struct ParsedSignaturePack: Hashable, Sendable {
    public var pack: SignaturePack
    public var skippedDecode: Int

    public init(pack: SignaturePack, skippedDecode: Int = 0) {
        self.pack = pack; self.skippedDecode = skippedDecode
    }
}

public struct SignatureImportResult: Hashable, Sendable {
    public var added: Int
    public var merged: Int
    public var skipped: Int
    public var renamed: Int
    public var error: String?

    public init(added: Int = 0, merged: Int = 0, skipped: Int = 0, renamed: Int = 0, error: String? = nil) {
        self.added = added; self.merged = merged; self.skipped = skipped; self.renamed = renamed; self.error = error
    }

    public func summary() -> String {
        if let error { return error }
        if added == 0 && merged == 0 {
            return skipped == 0 ? "Nothing to import." : "Nothing new. \(skipped) already on this Mac."
        }
        var parts: [String] = []
        if added > 0 {
            parts.append(renamed > 0 ? "Added \(added) (\(renamed) renamed)" : "Added \(added)")
        }
        if merged > 0 { parts.append("merged extra rules on \(merged)") }
        if skipped > 0 { parts.append("skipped \(skipped) already present") }
        return parts.joined(separator: " · ").capitalizedFirst() + "."
    }
}

/// Kotlin `text.trim().trimStart('﻿')`.
func exchangeTrimmed(_ text: String) -> String {
    var scalars = Substring(text.trim()).unicodeScalars
    while let f = scalars.first, f == "\u{FEFF}" { scalars.removeFirst() }
    return String(scalars)
}

public enum SignatureExchange {
    /// Kotlin `json` (prettyPrint, encodeDefaults): encoder half.
    public static var jsonEncoder: JSONEncoder {
        let e = JSONEncoder()
        // .sortedKeys: JSONEncoder writes object keys (and dictionary keys like `enum`) in per-launch hash
        // order otherwise. Kotlin wrote a fixed order; sorted keeps the file the same every run.
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return e
    }

    /// Kotlin `json` (ignoreUnknownKeys): decoder half. Unknown keys are ignored by Codable already.
    public static var jsonDecoder: JSONDecoder { JSONDecoder() }

    /// The stock catalog pack bundled with FieldwatchCore (dist/fieldwatch-signatures-v2.json on Android).
    public static func stockPackURL() -> URL? {
        Bundle.module.url(forResource: "fieldwatch-signatures-v2", withExtension: "json")
    }

    public static func pack(fleets: [Fleet], catalogVersion: Int, appVersion: String, exportedAt: String) -> SignaturePack {
        SignaturePack(
            format: SignaturePack.FORMAT,
            formatVersion: SignaturePack.FORMAT_VERSION,
            exportedAt: exportedAt,
            appVersion: appVersion,
            catalogVersion: catalogVersion,
            fleets: fleets
        )
    }

    public static func encode(pack: SignaturePack) -> String {
        // Encoding plain Codable values does not fail; empty string mirrors "nothing written".
        guard let data = try? jsonEncoder.encode(pack) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(text: String) throws -> SignaturePack { try parsePack(text: text).pack }

    /// Same as `parse`, plus how many decode maps were dropped because `DecodeSource`
    /// was unknown. Signatures still import; those rows just have no field map.
    public static func parsePack(text: String) throws -> ParsedSignaturePack {
        let trimmed = exchangeTrimmed(text)
        if trimmed.isEmpty {
            throw ExchangeError("This file is empty.")
        }
        let pack: SignaturePack
        do {
            pack = try jsonDecoder.decode(SignaturePack.self, from: Data(trimmed.utf8))
        } catch {
            throw ExchangeError("Not a Fieldwatch signature pack. Export from Settings → Export signatures.")
        }
        if pack.format != SignaturePack.FORMAT && pack.format != SignaturePack.LEGACY_FORMAT {
            throw ExchangeError(
                "Not a Fieldwatch signature pack (open a fieldwatch-signatures JSON file; spectre-signatures still imports)."
            )
        }
        if pack.fleets.isEmpty {
            throw ExchangeError("This pack has no signatures.")
        }
        var skipped = 0
        let fleets = pack.fleets.map { fleet -> Fleet in
            if fleet.decode?.source == .unsupported {
                skipped += 1
                var f = fleet
                f.decode = nil
                return f
            }
            return fleet
        }
        var out = pack
        out.fleets = fleets
        return ParsedSignaturePack(pack: out, skippedDecode: skipped)
    }

    public static func merge(existing: [Fleet], incoming: [Fleet]) -> ([Fleet], SignatureImportResult) {
        if incoming.isEmpty {
            return (existing, SignatureImportResult(error: "This pack has no signatures."))
        }
        let stockIds = Set(DefaultCatalog.fleets().map { $0.id })
        var next = existing
        var byId: [String: Int] = [:]
        for (index, fleet) in next.enumerated() { byId[fleet.id] = index }
        var fingerprints = Set(next.map { fingerprint(fleet: $0) })
        var names = Set(next.map { $0.name.trim().lowercased() })
        var added = 0
        var merged = 0
        var skipped = 0
        var renamed = 0

        for raw in incoming {
            var fleet = raw
            fleet.id = raw.id.ifBlank(UUID().uuidString.lowercased())
            fleet.kind = raw.kind.folded()
            if fleet.rules.isEmpty {
                skipped += 1
                continue
            }
            if let index = byId[fleet.id] {
                let local = next[index]
                let have = Set(local.rules.map { ruleKey(rule: $0) })
                let missing = fleet.rules.filter { !have.contains(ruleKey(rule: $0)) }
                let decode = fleet.decode ?? local.decode
                let decodeChanged = decode != local.decode
                if missing.isEmpty && !decodeChanged {
                    skipped += 1
                } else {
                    var updated = local
                    updated.rules = local.rules + missing
                    updated.decode = decode
                    next[index] = updated
                    fingerprints.remove(fingerprint(fleet: local))
                    fingerprints.insert(fingerprint(fleet: updated))
                    merged += 1
                }
                continue
            }
            let fp = fingerprint(fleet: fleet)
            if fingerprints.contains(fp) {
                skipped += 1
                continue
            }
            let (name, didRename) = uniqueName(desired: fleet.name, taken: names)
            var imported = fleet
            imported.name = name
            imported.builtIn = stockIds.contains(fleet.id)
            next.append(imported)
            byId[imported.id] = next.lastIndex
            fingerprints.insert(fingerprint(fleet: imported))
            names.insert(imported.name.trim().lowercased())
            added += 1
            if didRename { renamed += 1 }
        }
        let sorted = next.sortedBy { $0.name.lowercased() }
        return (sorted, SignatureImportResult(added: added, merged: merged, skipped: skipped, renamed: renamed))
    }

    public static func fingerprint(fleet: Fleet) -> String {
        let rules = fleet.rules.map { ruleKey(rule: $0) }.sorted()
        return [
            fleet.matchAny ? "ANY" : "ALL",
            String(fleet.minPeers),
            String(fleet.peerWindowSec),
            String(fleet.clusterByOui),
            String(fleet.sequentialMac),
            rules.joined(separator: ";"),
        ].joined(separator: "|")
    }

    public static func ruleKey(rule: MatchRule) -> String {
        [
            rule.kind.rawValue,
            rule.text.uppercased(),
            String(rule.companyId),
            rule.dataPrefixHex.uppercased(),
            rule.radio?.rawValue ?? "",
            String(rule.enabled),
        ].joined(separator: "|")
    }

    private static func uniqueName(desired: String, taken: Set<String>) -> (String, Bool) {
        let base = desired.trim().ifBlank("Imported signature")
        if !taken.contains(base.lowercased()) { return (base, false) }
        let imported = "\(base) (imported)"
        if !taken.contains(imported.lowercased()) { return (imported, true) }
        var i = 2
        while taken.contains("\(base) (imported \(i))".lowercased()) { i += 1 }
        return ("\(base) (imported \(i))", true)
    }

    /// Replace stock rows from a GitHub / file pack. Keeps user mute (`Fleet.enabled`),
    /// extra rules they added on a stock id, and every custom row. Does not touch
    /// watchlist or Settings.
    public static func overlayStock(existing: [Fleet], incoming: [Fleet]) -> ([Fleet], StockCatalogUpdateResult) {
        let stockIn = incoming
            .filter { $0.builtIn || $0.id.hasPrefix("fleet-") }
            .filter { $0.rules.isNotEmpty }
            .map { f -> Fleet in
                var s = f
                s.kind = f.kind.folded()
                s.builtIn = true
                return s
            }
        if stockIn.isEmpty {
            return (existing, StockCatalogUpdateResult(error: "This pack has no stock signatures."))
        }
        var byId: [String: Int] = [:]
        for (index, fleet) in existing.enumerated() { byId[fleet.id] = index }
        var next = existing
        var added = 0
        var updated = 0
        for stock in stockIn {
            guard let index = byId[stock.id] else {
                next.append(stock)
                byId[stock.id] = next.lastIndex
                added += 1
                continue
            }
            let local = next[index]
            if !local.builtIn { continue }
            let stockKeys = Set(stock.rules.map { ruleKey(rule: $0) })
            let extras = local.rules.filter { !stockKeys.contains(ruleKey(rule: $0)) }
            var overlaid = stock
            overlaid.enabled = local.enabled
            overlaid.rules = stock.rules + extras
            overlaid.builtIn = true
            overlaid.decode = stock.decode ?? local.decode
            if stockFieldsDiffer(local: local, overlaid: overlaid) {
                next[index] = overlaid
                updated += 1
            }
        }
        let incomingIds = Set(stockIn.map { $0.id })
        if !incomingIds.contains("fleet-unknown") {
            next.removeAll { $0.builtIn && $0.id == "fleet-unknown" }
        }
        let sorted = next.sortedBy { $0.name.lowercased() }
        return (sorted, StockCatalogUpdateResult(added: added, updated: updated))
    }

    private static func stockFieldsDiffer(local: Fleet, overlaid: Fleet) -> Bool {
        if local.name != overlaid.name { return true }
        if local.kind != overlaid.kind { return true }
        if local.colorIndex != overlaid.colorIndex { return true }
        if local.notes != overlaid.notes { return true }
        if local.attentionNote != overlaid.attentionNote { return true }
        if local.matchAny != overlaid.matchAny { return true }
        if local.minPeers != overlaid.minPeers { return true }
        if local.peerWindowSec != overlaid.peerWindowSec { return true }
        if local.clusterByOui != overlaid.clusterByOui { return true }
        if local.sequentialMac != overlaid.sequentialMac { return true }
        if local.decode != overlaid.decode { return true }
        if local.rules.map({ ruleKey(rule: $0) }) != overlaid.rules.map({ ruleKey(rule: $0) }) { return true }
        return false
    }
}
