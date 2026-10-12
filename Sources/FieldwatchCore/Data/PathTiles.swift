import CoreGraphics
import Foundation

/// Optional OSM raster under Reports → Path and the letter path figure.
/// Same switch as Online place names and maps. Privacy mode does not hide tiles.
/// Never throws; offline or a failed fetch returns an empty list (plain trace).
///
/// Port of data/PathTiles.kt. Android `Bitmap` → `CGImage`; Android `Context` is dropped;
/// `suspend` → blocking (call off the main thread). Tiles are cached under `FieldwatchPaths.dir("cache/osm")`.
public enum PathTiles {
    public struct Tile {
        public var bitmap: CGImage
        public var north: Double
        public var south: Double
        public var west: Double
        public var east: Double

        public init(bitmap: CGImage, north: Double, south: Double, west: Double, east: Double) {
            self.bitmap = bitmap; self.north = north; self.south = south; self.west = west; self.east = east
        }
    }

    /// OSM tile usage policy: identify the app. Same shape as the Android User-Agent.
    public static var userAgent: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.nonBlank ?? "1.1.25"
        return "Fieldwatch/\(version) (https://github.com/OffGridPete/Fieldwatch)"
    }

    public static func load(samples: [GpsSample], onlineLookup: Bool) -> [Tile] {
        if !onlineLookup { return [] }
        if samples.isEmpty { return [] }
        if !PlaceLookup.online() { return [] }
        return loadInner(samples: samples)
    }

    private static func loadInner(samples: [GpsSample]) -> [Tile] {
        let rawMinLat = samples.map { $0.lat }.min()!
        let rawMaxLat = samples.map { $0.lat }.max()!
        let rawMinLon = samples.map { $0.lon }.min()!
        let rawMaxLon = samples.map { $0.lon }.max()!
        let expanded = expandToPlot(minLat: rawMinLat, maxLat: rawMaxLat, minLon: rawMinLon, maxLon: rawMaxLon)
        let minLat = expanded[0]
        let maxLat = expanded[1]
        let minLon = expanded[2]
        let maxLon = expanded[3]
        let midLat = (minLat + maxLat) / 2.0
        let spanM = Geo.meters(lat1: minLat, lon1: minLon, lat2: maxLat, lon2: maxLon).coerceAtLeast(40.0)
        var z = zoomFor(spanM: spanM, lat: midLat)
        var box = tileBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, z: z)
        while box.count > 20 && z > 8 {
            z -= 1
            box = tileBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, z: z)
        }
        if box.isEmpty { return [] }
        let cache = FieldwatchPaths.dir("cache/osm")
        var out: [Tile] = []
        out.reserveCapacity(box.count)
        for (x, y) in box {
            guard let bmp = tileBitmap(cache: cache, z: z, x: x, y: y) else { continue }
            let n = tileLat(y: y, z: z)
            let s = tileLat(y: y + 1, z: z)
            let w = tileLon(x: x, z: z)
            let e = tileLon(x: x + 1, z: z)
            out.append(Tile(bitmap: bmp, north: n, south: s, west: w, east: e))
        }
        return out
    }

    /// Grow the path bbox to the Path plot aspect so tiles fill the allotted box, not a skinny strip.
    /// Returns [minLat, maxLat, minLon, maxLon] (Kotlin DoubleArray).
    static func expandToPlot(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        targetAspect: Double = 1.7
    ) -> [Double] {
        let midLat = (minLat + maxLat) / 2.0
        let midLon = (minLon + maxLon) / 2.0
        let cosLat = abs(cos(midLat * .pi / 180.0)).coerceAtLeast(0.2)
        let minM = Double(SitPathPlot.MIN_HALF_SPAN_M) * 2.0 * 1.22
        var yM = ((maxLat - minLat) * 110_540.0).coerceAtLeast(minM)
        var xM = ((maxLon - minLon) * 111_320.0 * cosLat).coerceAtLeast(minM)
        if xM / yM < targetAspect {
            xM = yM * targetAspect
        } else {
            yM = xM / targetAspect
        }
        xM *= 1.35
        yM *= 1.35
        let dLat = yM / 2.0 / 110_540.0
        let dLon = xM / 2.0 / (111_320.0 * cosLat)
        return [midLat - dLat, midLat + dLat, midLon - dLon, midLon + dLon]
    }

    static func zoomFor(spanM: Double, lat: Double) -> Int {
        let earth = 40_075_016.686 * abs(cos(lat * .pi / 180.0)).coerceAtLeast(0.2)
        for z in stride(from: 17, through: 8, by: -1) {
            let tileM = earth / Double(1 << z)
            if tileM * 2.2 >= spanM { return z }
        }
        return 8
    }

    private static func tileBox(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, z: Int) -> [(Int, Int)] {
        let x0 = lon2tile(lon: minLon, z: z)
        let x1 = lon2tile(lon: maxLon, z: z)
        let y0 = lat2tile(lat: maxLat, z: z)
        let y1 = lat2tile(lat: minLat, z: z)
        let n = 1 << z
        let xLo = min(x0, x1).coerceIn(0, n - 1), xHi = max(x0, x1).coerceIn(0, n - 1)
        let yLo = min(y0, y1).coerceIn(0, n - 1), yHi = max(y0, y1).coerceIn(0, n - 1)
        var out: [(Int, Int)] = []
        for x in xLo...xHi { for y in yLo...yHi { out.append((x, y)) } }
        return out
    }

    private static func lon2tile(lon: Double, z: Int) -> Int {
        let n = Double(1 << z)
        return Int(floor((lon + 180.0) / 360.0 * n))
    }

    private static func lat2tile(lat: Double, z: Int) -> Int {
        let n = Double(1 << z)
        let latRad = lat.coerceIn(-85.0511, 85.0511) * .pi / 180.0
        return Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
    }

    private static func tileLon(x: Int, z: Int) -> Double {
        let n = Double(1 << z)
        return Double(x) / n * 360.0 - 180.0
    }

    private static func tileLat(y: Int, z: Int) -> Double {
        let n = Double(1 << z)
        let t = Double.pi - 2.0 * Double.pi * Double(y) / n
        return atan(sinh(t)) * 180.0 / .pi
    }

    private static func decodePng(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func tileBitmap(cache: URL, z: Int, x: Int, y: Int) -> CGImage? {
        let file = cache.appendingPathComponent("\(z)_\(x)_\(y).png")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           (attrs[.type] as? FileAttributeType) == .typeRegular,
           ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 64,
           let cached = try? Data(contentsOf: file) {
            return decodePng(cached)
        }
        guard let url = URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let bytes = fetch(req, waitSec: 8) else { return nil }
        if bytes.count < 64 { return nil }
        try? bytes.write(to: file, options: .atomic)
        return decodePng(bytes)
    }

    /// Blocking GET. Nil unless HTTP 200 (redirects are followed by URLSession).
    private static func fetch(_ req: URLRequest, waitSec: Double) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if err == nil, let http = resp as? HTTPURLResponse, http.statusCode == 200 { box.data = data }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + waitSec) == .timedOut {
            task.cancel()
            return nil
        }
        return box.data
    }

    private final class ResultBox: @unchecked Sendable { var data: Data? }
}
