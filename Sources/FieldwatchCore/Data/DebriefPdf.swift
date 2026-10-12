import CoreGraphics
import CoreText
import Foundation

/// Letter-size field debrief. Content is measured first, packed into pages, then each page
/// is drawn and finished before the next starts.
///
/// Port of data/DebriefPdf.kt. Android `PdfDocument` + `Canvas` + `Paint` + `StaticLayout` →
/// a CoreGraphics PDF context (y-down page transform) with CoreText line layout.
/// Same page size (US Letter, 612 × 792 pt), margins, colours, typography roles and pagination.
/// Android's sans-serif (Roboto) is drawn with Helvetica.
public enum DebriefPdf {
    private static let PAGE_W = 612.0
    private static let PAGE_H = 792.0
    private static let MARGIN = 48.0
    private static let HEADER_H = 40.0
    private static let FOOTER_H = 36.0
    private static let INK = parseColor("#12171C")
    private static let MUTED = parseColor("#4A5560")
    private static let PHOS = parseColor("#0B7A48")
    private static let HEADER_BG = parseColor("#063D26")
    private static let ALERT_BG = parseColor("#FFF6E5")
    private static let ALERT_BAR = parseColor("#C47A00")
    private static let RULE = parseColor("#C5CDD4")
    private static let TAKE_BG = parseColor("#E8F5EE")
    private static let META_RULE = parseColor("#E2E8ED")
    private static let PLOT_PANEL = parseColor("#F4F7F5")
    private static let PLOT_INNER = parseColor("#FFFFFF")
    private static let PLOT_GRID = parseColor("#E4EBE6")
    private static let PATH_OTHER = parseColor("#4A6FA5")
    private static let AIRCRAFT = parseColor("#C47A00")
    private static let AIRCRAFT_INK = parseColor("#111111")
    private static let CLASS_DISC = parseColor("#FFB020")
    private static let PILOT_INK = parseColor("#3D4A55")
    private static let PILOT_FILL = parseColor("#F4F7FB")
    private static let PATH_STAY = parseColor("#35D683")
    private static let DOT_ATTENTION = parseColor("#E53935")
    private static let DOT_BOOKMARK = parseColor("#0288D1")
    private static let GNSS_INK = parseColor("#B91C1C")
    private static let WHITE = parseColor("#FFFFFF")
    private static let MARK_STAY = 1
    private static let MARK_SLATE = 2
    private static let MARK_AMBER = 3
    private static let MARK_AMBER_DASH = 4
    private static let MARK_RED = 5
    private static let MARK_BLUE = 6
    private static let MARK_PILOT = 7
    private static let MARK_ALERT = 8
    private static let MARK_GNSS = 9
    private static let MARK_GNSS_2 = 10
    private static let CONTENT_W = Int(PAGE_W - 2 * MARGIN)
    private static let BODY_TOP = HEADER_H + 18.0
    private static let BODY_BOT = PAGE_H - FOOTER_H - 8.0
    private static let USABLE = BODY_BOT - BODY_TOP

    /// Render the debrief and write it to `file` (parent folders are created).
    public static func write(
        doc: DebriefDoc,
        file: URL,
        tiles: [PathTiles.Tile] = [],
        extraTiles: [[PathTiles.Tile]] = [],
        onProgress: (Double) -> Void = { _ in }
    ) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = render(doc: doc, tiles: tiles, extraTiles: extraTiles, onProgress: { p in
            if p < 1.0 { onProgress(p) }
        })
        try data.write(to: file, options: .atomic)
        onProgress(1.0)
    }

    /// The PDF bytes ("%PDF-…").
    public static func render(
        doc: DebriefDoc,
        tiles: [PathTiles.Tile] = [],
        extraTiles: [[PathTiles.Tile]] = [],
        onProgress: (Double) -> Void = { _ in }
    ) -> Data {
        onProgress(0.08)
        let blocks = layoutBlocks(doc: doc, tiles: tiles, extraTiles: extraTiles)
        onProgress(0.18)
        let pages = paginate(blocks)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return Data() }
        var media = CGRect(x: 0, y: 0, width: PAGE_W, height: PAGE_H)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return Data() }
        let n = pages.count.coerceAtLeast(1)
        for (i, pageBlocks) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Android canvas space: origin top-left, y down.
            ctx.translateBy(x: 0, y: PAGE_H)
            ctx.scaleBy(x: 1, y: -1)
            var y = BODY_TOP
            for block in pageBlocks {
                ctx.saveGState()
                block.draw(ctx, y)
                ctx.restoreGState()
                y += block.height
            }
            stampChrome(ctx, page: i + 1, total: pages.count, doc: doc)
            ctx.restoreGState()
            ctx.endPDFPage()
            onProgress(0.18 + 0.72 * Double(i + 1) / Double(n))
        }
        onProgress(0.94)
        ctx.closePDF()
        onProgress(1.0)
        return out as Data
    }

    private struct Block {
        let height: Double
        var keepWithNext: Bool = false
        let draw: (CGContext, Double) -> Void
    }

    private static func layoutBlocks(doc: DebriefDoc, tiles: [PathTiles.Tile], extraTiles: [[PathTiles.Tile]]) -> [Block] {
        var out: [Block] = []
        out.append(titleBlock(doc.pdfTitle))
        out.append(spacer(6))
        out.append(sectionHead(number: "", title: "Disclaimer", alert: false))
        for para in doc.disclaimer.split("\n\n") {
            for sl in chunkText(para.trim().ifBlank(" "), width: CONTENT_W, size: 9, muted: true) {
                out.append(textBlock(sl))
            }
            out.append(spacer(6))
        }
        out.append(ruleBlock())
        for (i, kv) in doc.meta.enumerated() {
            out.append(metaRow(key: kv.0, value: kv.1, zebra: i % 2 == 0))
        }
        out.append(spacer(8))
        if let figure = doc.pathFigure, figure.drawable {
            out.append(pathFigureBlock(figure, tiles: tiles))
            out.append(spacer(4))
            out.append(contentsOf: pathKeyBlocks(figure))
            out.append(spacer(10))
        }
        for (index, extra) in doc.extraFigures.enumerated() {
            if !extra.drawable { continue }
            out.append(pathFigureBlock(extra, tiles: extraTiles.getOrNull(index) ?? []))
            out.append(spacer(10))
        }
        for section in doc.sections {
            if section.title == "Extra attention" && doc.extraAttention.isNotEmpty {
                out.append(sectionHead(number: section.number, title: section.title, alert: true))
                out.append(spacer(4))
                for hit in doc.extraAttention {
                    out.append(attentionNoteBlock(hit))
                    out.append(spacer(8))
                }
                continue
            }
            out.append(sectionHead(number: section.number, title: section.title, alert: section.alert))
            appendProse(&out, section.body, alert: section.alert)
            if let chart = section.chart, chart.rows.isNotEmpty {
                out.append(contentsOf: chartBlocks(chart))
                out.append(spacer(6))
            }
            appendProse(&out, section.after, alert: section.alert)
            out.append(spacer(8))
        }
        out.append(takeawayBlock(doc.takeaway))
        return out
    }

    private static func appendProse(_ out: inout [Block], _ text: String, alert: Bool) {
        if text.isBlank { return }
        let paras = text.split("\n")
        let width = CONTENT_W - (alert ? 12 : 0)
        for (i, raw) in paras.enumerated() {
            let para = raw.trimEnd()
            if para.isBlank {
                out.append(spacer(5))
            } else if isStayHead(para) {
                if i > 0 { out.append(spacer(8)) }
                out.append(subheadBlock(para.trim(), alert: alert))
            } else if isKickerLine(para) {
                if i > 0 { out.append(spacer(6)) }
                out.append(kickerLineBlock(para.trim(), alert: alert))
            } else if isBullet(para) {
                out.append(bulletBlock(
                    removePrefix(removePrefix(para.trimStart(), "·").trimStart(), "•").trim(),
                    alert: alert
                ))
            } else {
                for sl in chunkText(para, width: width, size: 9.5, muted: false) {
                    out.append(bodyBlock(sl, alert: alert))
                }
            }
        }
    }

    private static func chartBlocks(_ chart: ReportChart) -> [Block] {
        var blocks: [Block] = []
        if chart.caption.isNotBlank {
            blocks.append(textBlock(layout(chart.caption, width: CONTENT_W, size: 8, muted: true)))
        }
        if chart.split {
            blocks.append(legendBlock())
        }
        let max = (chart.rows.map { Swift.max($0.value, $0.second ?? 0) }.max() ?? 0).coerceAtLeast(1)
        for row in chart.rows { blocks.append(barBlock(row, max: max, split: chart.split)) }
        return blocks
    }

    private static func legendBlock() -> Block {
        Block(height: 14) { ctx, y in
            let paint = TextStyle(color: MUTED, size: 8)
            drawLegendSwatch(ctx, x: MARGIN, y: y + 3, color: PHOS)
            paint.drawText(ctx, "Wi-Fi", MARGIN + 14, y + 10)
            drawLegendSwatch(ctx, x: MARGIN + 58, y: y + 3, color: PATH_OTHER)
            paint.drawText(ctx, "BLE", MARGIN + 72, y + 10)
        }
    }

    private static func drawLegendSwatch(_ ctx: CGContext, x: Double, y: Double, color: CGColor) {
        fillRoundRect(ctx, CGRect(x: x, y: y, width: 10, height: 6), 2, color)
    }

    private static func barBlock(_ row: ReportBar, max: Int, split: Bool) -> Block {
        let height = split ? 28.0 : 16.0
        return Block(height: height) { ctx, y in
            let labelPaint = TextStyle(color: INK, size: 9)
            let numPaint = TextStyle(color: INK, size: 9, bold: true)
            let detailPaint = TextStyle(color: MUTED, size: 8)
            let labelW = 148.0
            let labelBase = split ? y + 16 : y + 10
            labelPaint.drawText(ctx, fitText(row.label, labelPaint, labelW), MARGIN, labelBase)
            let barLeft = MARGIN + labelW + 8
            let numW = 32.0
            let detailW = (split || row.detail.isBlank) ? 0.0 : 118.0
            let barRight = PAGE_W - MARGIN - numW - detailW - 8
            func drawOne(_ value: Int, _ top: Double, _ color: CGColor) {
                fillRoundRect(ctx, CGRect(x: barLeft, y: top, width: barRight - barLeft, height: 7), 3, parseColor("#E6EEE9"))
                if value > 0 {
                    let frac = (Double(value) / Double(max)).coerceIn(0.03, 1.0)
                    fillRoundRect(ctx, CGRect(x: barLeft, y: top, width: (barRight - barLeft) * frac, height: 7), 3, color)
                }
                numPaint.drawText(ctx, "\(value)", barRight + 6, top + 7)
            }
            if split {
                drawOne(row.value, y + 2, PHOS)
                drawOne(row.second ?? 0, y + 14, PATH_OTHER)
            } else {
                drawOne(row.value, y + 2, PHOS)
                if row.detail.isNotBlank {
                    detailPaint.drawText(ctx, row.detail, barRight + numW + 8, y + 10)
                }
            }
        }
    }

    private static func fitText(_ text: String, _ paint: TextStyle, _ width: Double) -> String {
        if paint.measureText(text) <= width { return text }
        var end = text.count
        while end > 1 && paint.measureText(text.substring(0, end) + "…") > width { end -= 1 }
        return text.substring(0, end) + "…"
    }

    private static func paginate(_ blocks: [Block]) -> [[Block]] {
        var pages: [[Block]] = []
        var current: [Block] = []
        var used = 0.0
        func flush() {
            if current.isEmpty { return }
            pages.append(current)
            current = []
            used = 0
        }
        for i in blocks.indices {
            let block = blocks[i]
            let h = block.height
            let need = (block.keepWithNext && i + 1 < blocks.count) ? h + blocks[i + 1].height.coerceAtMost(28) : h
            if current.isNotEmpty && used + need > USABLE { flush() }
            if h > USABLE && current.isEmpty {
                current.append(block)
                flush()
                continue
            }
            current.append(block)
            used += h
        }
        flush()
        if pages.isEmpty { pages.append([]) }
        return pages
    }

    private static func titleBlock(_ text: String) -> Block {
        Block(height: 26) { ctx, y in
            TextStyle(color: INK, size: 18, bold: true).drawText(ctx, text, MARGIN, y + 16)
        }
    }

    private static func metaRow(key: String, value: String, zebra: Bool) -> Block {
        let valueLayout = layout(value, width: CONTENT_W - 96, size: 9, muted: false)
        let h = Swift.max(16, valueLayout.height + 8)
        return Block(height: h) { ctx, y in
            if zebra {
                fillRect(ctx, MARGIN - 4, y, PAGE_W - MARGIN + 4, y + h, META_RULE)
            }
            TextStyle(color: PHOS, size: 8, bold: true).drawText(ctx, key.uppercase(), MARGIN + 4, y + 12)
            valueLayout.draw(ctx, x: MARGIN + 96, y: y + 4)
        }
    }

    private static func ruleBlock() -> Block {
        Block(height: 14) { ctx, y in
            line(ctx, MARGIN, y + 6, PAGE_W - MARGIN, y + 6, Pen(color: RULE, width: 0.8))
        }
    }

    private static func spacer(_ h: Double) -> Block { Block(height: h) { _, _ in } }

    private static func figurePlotSize() -> (Double, Double) { (PAGE_W - 2 * MARGIN - 16, 300) }

    private static func pathFigureBlock(_ fig: SitPathPlot.Figure, tiles: [PathTiles.Tile]) -> Block {
        let legend = legendRows(fig)
        let headerH = 20.0 + Double(legend.count) * 13.0 + 6.0
        let (plotW, plotH) = figurePlotSize()
        let cap = layout(fig.caption, width: CONTENT_W - 24, size: 8, muted: true)
        let scaleH = 20.0
        let h = headerH + plotH + 14 + scaleH + 8 + cap.height + 12
        return Block(height: h) { ctx, y in
            let panel = CGRect(x: MARGIN, y: y, width: PAGE_W - 2 * MARGIN, height: h)
            let stroke = Pen(color: RULE, width: 0.9)
            fillRoundRect(ctx, panel, 7, PLOT_PANEL)
            strokeRoundRect(ctx, panel, 7, stroke)
            let kicker = TextStyle(color: fig.kicker == "AIRCRAFT" ? AIRCRAFT : PHOS, size: 8, bold: true, letterSpacing: 0.12)
            kicker.drawText(ctx, fig.kicker, MARGIN + 8, y + 15)
            let stats = TextStyle(color: MUTED, size: 8)
            let span = fig.spanM >= 1000 ? "\(fmt(fig.spanM / 1000, 1)) km span" : "\(fig.spanM.toIntTruncating()) m span"
            let len = fig.lengthM >= 1000 ? "\(fmt(fig.lengthM / 1000, 1)) km path" : "\(fig.lengthM.toIntTruncating()) m path"
            let fixes = fig.tracks.filter { $0.aircraft }.sumOf { $0.samples.count }
            let right = (fig.tracks.allSatisfy { $0.aircraft } && fixes == 1) ? "1 advertised fix" : "\(len)  ·  \(span)"
            stats.drawText(ctx, right, PAGE_W - MARGIN - 8 - stats.measureText(right), y + 15)
            drawLegend(ctx, left: MARGIN + 8, top: y + 22, right: PAGE_W - MARGIN - 8, rows: legend)
            let plotTop = y + headerH
            let plot = CGRect(x: MARGIN + 8, y: plotTop, width: plotW, height: plotH)
            fillRect(ctx, plot.minX, plot.minY, plot.maxX, plot.maxY, PLOT_INNER)
            let model = figureModel(fig)
            if let lay = SitPathPlot.layout(model: model, width: plot.width, height: plot.height, pad: 12, scaleBarReserve: 0) {
                drawPathMap(ctx, plot: plot, lay: lay, fig: fig, tiles: tiles, stroke: stroke)
            } else {
                strokeRect(ctx, plot, stroke)
            }
            cap.draw(ctx, x: MARGIN + 8, y: plot.maxY + 14 + scaleH)
        }
    }

    private static func drawPathMap(
        _ ctx: CGContext,
        plot: CGRect,
        lay: SitPathPlot.Layout,
        fig: SitPathPlot.Figure,
        tiles: [PathTiles.Tile],
        stroke: Pen
    ) {
        let ox: (Double) -> Double = { x in Double(plot.minX) + x }
        let oy: (Double) -> Double = { y in Double(plot.minY) + y }
        ctx.saveGState()
        ctx.clip(to: plot)
        if tiles.isEmpty {
            let grid = Pen(color: PLOT_GRID, width: 0.6)
            for i in 1...3 {
                let gx = plot.minX + plot.width * Double(i) / 4.0
                let gy = plot.minY + plot.height * Double(i) / 4.0
                line(ctx, gx, plot.minY, gx, plot.maxY, grid)
                line(ctx, plot.minX, gy, plot.maxX, gy, grid)
            }
        } else {
            for tile in tiles {
                let nw = lay.project(tile.north, tile.west)
                let se = lay.project(tile.south, tile.east)
                let dst = CGRect(x: ox(Double(nw.x)), y: oy(Double(nw.y)),
                                 width: Double(se.x) - Double(nw.x), height: Double(se.y) - Double(nw.y))
                if dst.width < 1 || dst.height < 1 { continue }
                ctx.saveGState()
                ctx.setAlpha(210.0 / 255.0)
                ctx.interpolationQuality = .high
                // Image space is y-up; flip locally so the tile is upright on the y-down page.
                ctx.translateBy(x: dst.minX, y: dst.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(tile.bitmap, in: CGRect(x: 0, y: 0, width: dst.width, height: dst.height))
                ctx.restoreGState()
            }
        }
        for track in fig.tracks {
            drawPathTrack(ctx, lay: lay, track: track, ox: ox, oy: oy)
        }
        let phonePrimary = fig.tracks.first { !$0.aircraft && !$0.secondary }
        if let phonePrimary, phonePrimary.samples.count >= 2, fig.tracks.filter({ !$0.aircraft }).count == 1 {
            drawPathTicks(ctx, lay: lay, samples: phonePrimary.samples, ox: ox, oy: oy, despike: true)
        }
        for pin in fig.gnss {
            let pt = lay.project(pin.lat, pin.lon)
            drawGnssMark(ctx, x: ox(Double(pt.x)), y: oy(Double(pt.y)), secondary: pin.secondary)
        }
        let craftPrimary = fig.tracks.first { $0.aircraft && !$0.secondary && $0.samples.count >= 2 }
        if phonePrimary == nil, let craftPrimary {
            drawPathTicks(ctx, lay: lay, samples: craftPrimary.samples, ox: ox, oy: oy, despike: false)
        }
        for mark in fig.pilots {
            let pt = lay.project(mark.lat, mark.lon)
            drawPilot(ctx, x: ox(Double(pt.x)), y: oy(Double(pt.y)))
        }
        let piles = SitPathPlot.clusters(dots: lay.dots)
        for (i, pile) in piles.enumerated() {
            let extra = pile.members.contains { $0.dot.extraAttention }
            let named = pile.members.contains { $0.dot.named }
            let fillD = extra ? DOT_ATTENTION : (named ? DOT_BOOKMARK : PHOS)
            let r = pile.stacked ? 8.5 : 7.0
            let cx = ox(Double(pile.center.x))
            let cy = oy(Double(pile.center.y))
            fillCircle(ctx, cx, cy, r, fillD)
            strokeCircle(ctx, cx, cy, r, Pen(color: WHITE, width: 1.4))
            let num = TextStyle(color: WHITE, size: pile.stacked ? 8 : 7, bold: true, center: true)
            num.drawText(ctx, "\(i + 1)", cx, cy + 2.6)
        }
        ctx.restoreGState()
        strokeRect(ctx, plot, stroke)
        let nP = TextStyle(color: MUTED, size: 8, bold: true, center: true)
        let nx = plot.maxX - 12
        let ny = plot.minY + 12
        fillCircle(ctx, nx, ny - 2, 8, argb(230, 255, 255, 255))
        nP.drawText(ctx, "N", nx, ny + 1)
        let barW = plot.width * Double(lay.scaleBarFrac)
        let label = lay.scaleBarM >= 1000 ? "\((lay.scaleBarM / 1000).toIntTruncating()) km" : "\(lay.scaleBarM.toIntTruncating()) m"
        let barPaint = Pen(color: MUTED, width: 1.6)
        let lab = TextStyle(color: MUTED, size: 8)
        let group = barW + 6 + lab.measureText(label)
        let bx = plot.midX - group / 2
        let by = plot.maxY + 16
        line(ctx, bx, by, bx + barW, by, barPaint)
        line(ctx, bx, by - 3.5, bx, by + 3.5, barPaint)
        line(ctx, bx + barW, by - 3.5, bx + barW, by + 3.5, barPaint)
        lab.drawText(ctx, label, bx + barW + 6, by + 3)
    }

    private static func drawPathTrack(
        _ ctx: CGContext,
        lay: SitPathPlot.Layout,
        track: SitPathPlot.FigureTrack,
        ox: (Double) -> Double,
        oy: (Double) -> Double
    ) {
        if track.samples.isEmpty { return }
        if track.samples.count == 1 {
            if !track.aircraft { return }
            let only = lay.project(track.samples[0].lat, track.samples[0].lon)
            drawClassMark(ctx, x: ox(Double(only.x)), y: oy(Double(only.y)))
            return
        }
        let cleaned: [GpsSample]
        if track.aircraft {
            cleaned = track.samples
        } else {
            let d = Geo.despikePath(samples: track.samples)
            cleaned = d.count >= 2 ? d : track.samples
        }
        let pts = cleaned.map { lay.project($0.lat, $0.lon) }
        func px(_ i: Int) -> Double { ox(Double(pts[i].x)) }
        func py(_ i: Int) -> Double { oy(Double(pts[i].y)) }
        let pth = CGMutablePath()
        pth.move(to: CGPoint(x: px(0), y: py(0)))
        for i in 1..<pts.count { pth.addLine(to: CGPoint(x: px(i), y: py(i))) }
        var tp = Pen(
            color: track.aircraft && track.secondary ? PATH_OTHER
                : track.aircraft ? AIRCRAFT_INK
                : track.secondary ? PATH_OTHER
                : parseColor("#2A3340"),
            width: track.aircraft ? 1.8 : (track.secondary ? 1.8 : 2.4),
            roundCap: true,
            roundJoin: true
        )
        if track.aircraft {
            tp.dash = [2.2, 3.8]
        } else if track.secondary {
            tp.dash = [7, 4.5]
        }
        strokePath(ctx, pth, tp)
        let last = pts.count - 1
        if track.aircraft {
            fillCircle(ctx, px(0), py(0), 3.2, WHITE)
            strokeCircle(ctx, px(0), py(0), 3.2, Pen(color: track.secondary ? PATH_OTHER : AIRCRAFT_INK, width: 1.4))
            drawClassMark(ctx, x: px(last), y: py(last))
            return
        }
        let stays = Geo.legs(samples: cleaned).filter { $0.stay }
        var stayPaint = Pen(
            color: track.secondary ? PATH_OTHER : PATH_STAY,
            width: track.secondary ? 4.5 : 7.2,
            roundCap: true
        )
        stayPaint.alpha = track.secondary ? 180 : 230
        if track.secondary { stayPaint.dash = [8, 5] }
        for i in 1..<pts.count {
            guard let t = cleaned.getOrNull(i)?.at else { continue }
            if stays.none({ t >= $0.startAt && t <= $0.endAt }) { continue }
            line(ctx, px(i - 1), py(i - 1), px(i), py(i), stayPaint)
        }
        if !track.secondary {
            let glow = PATH_STAY.copy(alpha: 48.0 / 255.0) ?? PATH_STAY
            for stay in stays {
                let pt = lay.project(stay.lat, stay.lon)
                fillCircle(ctx, ox(Double(pt.x)), oy(Double(pt.y)), 14, glow)
            }
        }
        let disc = track.secondary ? PATH_OTHER : PHOS
        fillCircle(ctx, px(0), py(0), 3.4, disc)
        fillCircle(ctx, px(last), py(last), 4.6, disc)
        if !track.secondary {
            let lab = TextStyle(color: MUTED, size: 7.5)
            lab.drawText(ctx, "Start", px(0) + 6, py(0) - 4)
            lab.drawText(ctx, "End", px(last) + 6, py(last) - 4)
        }
    }

    private struct LegendSwatch {
        let label: String
        let mark: Int
    }

    private static func legendSwatches(_ fig: SitPathPlot.Figure) -> [LegendSwatch] {
        let phone = fig.tracks.filter { !$0.aircraft }
        var out: [LegendSwatch] = []
        if phone.count >= 2 {
            out.append(LegendSwatch(label: "This sit", mark: MARK_STAY))
            out.append(LegendSwatch(label: "Second sit", mark: MARK_SLATE))
        } else if phone.contains(where: { $0.samples.count >= 2 }) {
            out.append(LegendSwatch(label: "Stay", mark: MARK_STAY))
        }
        let craft = fig.tracks.filter { $0.aircraft }
        if craft.isNotEmpty {
            out.append(LegendSwatch(label: "Advertised", mark: MARK_AMBER))
            if craft.contains(where: { $0.secondary }) { out.append(LegendSwatch(label: "Second advertised", mark: MARK_AMBER_DASH)) }
        }
        if fig.dots.contains(where: { $0.extraAttention }) { out.append(LegendSwatch(label: "Extra attention", mark: MARK_RED)) }
        if fig.dots.contains(where: { $0.named }) { out.append(LegendSwatch(label: "MAC alert", mark: MARK_BLUE)) }
        if fig.dots.contains(where: { !$0.extraAttention && !$0.named }) { out.append(LegendSwatch(label: "Signature alert", mark: MARK_ALERT)) }
        if fig.pilots.isNotEmpty { out.append(LegendSwatch(label: "Pilot", mark: MARK_PILOT)) }
        if fig.gnss.contains(where: { !$0.secondary }) { out.append(LegendSwatch(label: "GNSS", mark: MARK_GNSS)) }
        if fig.gnss.contains(where: { $0.secondary }) { out.append(LegendSwatch(label: "Second GNSS", mark: MARK_GNSS_2)) }
        return out
    }

    private static func legendRows(_ fig: SitPathPlot.Figure) -> [[LegendSwatch]] {
        let bits = legendSwatches(fig)
        if bits.isEmpty { return [] }
        let paint = legendLabelPaint()
        let maxW = PAGE_W - 2 * MARGIN - 16
        var rows: [[LegendSwatch]] = []
        var row: [LegendSwatch] = []
        var used = 0.0
        for bit in bits {
            let w = swatchAdvance(paint, bit.label)
            if row.isNotEmpty && used + w > maxW {
                rows.append(row)
                row = []
                used = 0
            }
            row.append(bit)
            used += w
        }
        if row.isNotEmpty { rows.append(row) }
        return rows
    }

    private static func legendLabelPaint() -> TextStyle { TextStyle(color: MUTED, size: 7.5) }

    private static func swatchAdvance(_ paint: TextStyle, _ label: String) -> Double { 14 + paint.measureText(label) + 10 }

    private static func drawLegend(_ ctx: CGContext, left: Double, top: Double, right: Double, rows: [[LegendSwatch]]) {
        let lab = legendLabelPaint()
        for (rowIndex, row) in rows.enumerated() {
            var x = left
            let y = top + Double(rowIndex) * 13
            for bit in row {
                drawSwatch(ctx, cx: x + 5, cy: y + 3, mark: bit.mark)
                lab.drawText(ctx, bit.label, x + 14, y + 6.5)
                x += swatchAdvance(lab, bit.label)
            }
        }
    }

    private static func drawSwatch(_ ctx: CGContext, cx: Double, cy: Double, mark: Int) {
        var stroke = Pen(color: INK, width: 2.2, roundCap: true)
        switch mark {
        case MARK_STAY:
            stroke.color = PATH_STAY
            stroke.width = 3.2
            line(ctx, cx - 5, cy, cx + 5, cy, stroke)
        case MARK_SLATE:
            stroke.color = PATH_OTHER
            stroke.dash = [2.4, 1.8]
            line(ctx, cx - 5, cy, cx + 5, cy, stroke)
        case MARK_AMBER:
            stroke.color = AIRCRAFT_INK
            stroke.width = 1.8
            stroke.dash = [1.6, 2.4]
            line(ctx, cx - 6, cy, cx + 6, cy, stroke)
        case MARK_AMBER_DASH:
            stroke.color = PATH_OTHER
            stroke.width = 1.8
            stroke.dash = [1.6, 2.4]
            line(ctx, cx - 6, cy, cx + 6, cy, stroke)
        case MARK_RED:
            fillCircle(ctx, cx, cy, 2.6, DOT_ATTENTION)
        case MARK_BLUE:
            fillCircle(ctx, cx, cy, 2.6, DOT_BOOKMARK)
        case MARK_ALERT:
            fillCircle(ctx, cx, cy, 2.6, PHOS)
        case MARK_PILOT:
            drawPilot(ctx, x: cx, y: cy, radius: 4.4)
        case MARK_GNSS:
            drawGnssMark(ctx, x: cx, y: cy, secondary: false, radius: 4.2)
        case MARK_GNSS_2:
            drawGnssMark(ctx, x: cx, y: cy, secondary: true, radius: 4.2)
        default:
            break
        }
    }

    private static func drawGnssMark(_ ctx: CGContext, x: Double, y: Double, secondary: Bool, radius: Double = 5.6) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y - radius))
        path.addLine(to: CGPoint(x: x + radius * 0.86, y: y))
        path.addLine(to: CGPoint(x: x, y: y + radius))
        path.addLine(to: CGPoint(x: x - radius * 0.86, y: y))
        path.closeSubpath()
        fillPath(ctx, path, secondary ? PATH_OTHER : GNSS_INK)
        strokePath(ctx, path, Pen(color: WHITE, width: 1.3))
    }

    private static func figureModel(_ fig: SitPathPlot.Figure) -> SitPathPlot.Model {
        let phone = fig.tracks.filter { !$0.aircraft }.flatMap { $0.samples }
        let craft = fig.tracks.filter { $0.aircraft }.flatMap { $0.samples } +
            fig.pilots.map { GpsSample(at: 0, lat: $0.lat, lon: $0.lon, rssi: 0) }
        return SitPathPlot.Model(
            samples: phone,
            dots: fig.dots,
            lengthM: fig.lengthM,
            spanM: fig.spanM,
            title: fig.kicker,
            frameSamples: craft,
            minHalfSpanM: (phone.isEmpty && Geo.spanM(samples: craft) < 80.0) ? 140 : 0
        )
    }

    private static func drawClassMark(_ ctx: CGContext, x: Double, y: Double, radius: Double = 7.2) {
        fillCircle(ctx, x, y, radius + 1.1, WHITE)
        fillCircle(ctx, x, y, radius, CLASS_DISC)
        drawGlyph(ctx, Glyphs.flight, cx: x, cy: y, size: radius * 1.25, color: WHITE)
    }

    private static func drawPilot(_ ctx: CGContext, x: Double, y: Double, radius: Double = 6.4) {
        fillCircle(ctx, x, y, radius + 0.7, WHITE)
        fillCircle(ctx, x, y, radius, PILOT_FILL)
        strokeCircle(ctx, x, y, radius, Pen(color: PILOT_INK, width: 1.1))
        drawGlyph(ctx, Glyphs.person, cx: x, cy: y, size: radius * 1.35, color: PILOT_INK)
    }

    /// Material icon (24 × 24 viewport) centred on (cx, cy).
    private static func drawGlyph(_ ctx: CGContext, _ vector: CGPath, cx: Double, cy: Double, size: Double, color: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: cx - size / 2, y: cy - size / 2)
        ctx.scaleBy(x: size / 24.0, y: size / 24.0)
        fillPath(ctx, vector, color)
        ctx.restoreGState()
    }

    private static func drawPathTicks(
        _ ctx: CGContext,
        lay: SitPathPlot.Layout,
        samples: [GpsSample],
        ox: (Double) -> Double,
        oy: (Double) -> Double,
        despike: Bool
    ) {
        let trace: [GpsSample]
        if despike {
            let d = Geo.despikePath(samples: samples)
            trace = d.count >= 2 ? d : samples
        } else {
            trace = samples
        }
        if trace.count < 2 { return }
        let dur = (trace.last!.at - trace.first!.at).coerceAtLeast(1)
        let lab = TextStyle(color: MUTED, size: 7)
        let chip = argb(228, 255, 255, 255)
        for frac in [0.25, 0.5, 0.75] {
            let want = trace.first!.at + Int(Double(dur) * frac)
            guard let idx = trace.indices.minByOrNull({ abs(trace[$0].at - want) }) else { continue }
            if idx == 0 || idx == trace.count - 1 { continue }
            let pt = lay.project(trace[idx].lat, trace[idx].lon)
            let label = formatMs(trace[idx].at, "HH:mm")
            let tx = ox(Double(pt.x)) + 5
            let ty = oy(Double(pt.y)) - 3
            let tw = lab.measureText(label)
            fillCircle(ctx, ox(Double(pt.x)), oy(Double(pt.y)), 2.4, MUTED)
            fillRoundRect(ctx, CGRect(x: tx - 1.5, y: ty - 7.5, width: tw + 3, height: 9.5), 2, chip)
            lab.drawText(ctx, label, tx, ty)
        }
    }

    private static func pathKeyBlocks(_ fig: SitPathPlot.Figure) -> [Block] {
        let model = figureModel(fig)
        let (plotW, plotH) = figurePlotSize()
        guard let lay = SitPathPlot.layout(model: model, width: plotW, height: plotH, pad: 12, scaleBarReserve: 0) else { return [] }
        let piles = SitPathPlot.clusters(dots: lay.dots)
        let craft = fig.craftKeys.filter { $0.isNotBlank }
        if piles.isEmpty && craft.isEmpty && fig.gnss.isEmpty { return [] }
        var out: [Block] = []
        out.append(sectionHead(number: "", title: "Path key", alert: false))
        out.append(spacer(4))
        for (i, pile) in piles.enumerated() {
            out.append(pathKeyRow(i + 1, pile))
            out.append(spacer(5))
        }
        for line in craft {
            out.append(pathKeyCraftRow(line))
            out.append(spacer(5))
        }
        for pin in fig.gnss {
            out.append(pathKeyGnssRow(pin))
            out.append(spacer(5))
        }
        return out
    }

    private static func pathKeyLine(_ n: Int, _ pile: SitPathPlot.Cluster) -> String {
        let radios = pile.members.map { m -> String in
            let d = m.dot
            let kind = d.kind.rawValue == "WIFI" ? "WIFI" : "BLE"
            let tag: String? = d.extraAttention ? "Extra attention" : nil
            let fleets = d.fleetNames.filter { $0.isNotBlank }.joined(separator: ", ")
            let obs = d.observerNotes.trim().nonEmpty.map { "Observer: \($0)" }
            let who = [kind, d.label.ifBlank(d.mac), fleets.nonBlank, tag, obs].compactMap { $0 }.joined(separator: " ")
            let advertised = d.advertisedNote.trim()
            return advertised.isEmpty ? who : "\(who) — \(advertised)"
        }.joined(separator: "  ·  ")
        return pile.stacked ? "\(n)  \(pile.members.count) radios at this stop — \(radios)" : "\(n)  \(radios)"
    }

    private static func textBlock(_ sl: TextLayout) -> Block {
        Block(height: sl.height + 4) { ctx, y in sl.draw(ctx, x: MARGIN, y: y) }
    }

    private static let stayHeadRe = KRegex(#"^\d+\.\s+(Stay|Transit)\b.*"#)
    private static let kickerRe = KRegex(#"^[A-Z][A-Za-z0-9 +/'()&.,-]{0,48}:(\s.*)?$"#)

    private static func isStayHead(_ line: String) -> Bool {
        let t = line.trim()
        return t.matches(stayHeadRe) || t.startsWith("• ")
    }

    private static func isKickerLine(_ line: String) -> Bool {
        let t = line.trim()
        if t.startsWith("Phone GPS") { return true }
        if t.contains(". ") { return false }
        return t.matches(kickerRe)
    }

    private static func isBullet(_ line: String) -> Bool {
        let t = line.trimStart()
        return t.startsWith("· ") || t.startsWith("• ")
    }

    private static func subheadBlock(_ text: String, alert: Bool) -> Block {
        let sl = layout(text, width: CONTENT_W - (alert ? 12 : 0), size: 10.5, muted: false, bold: true)
        let h = sl.height + 6
        return Block(height: h, keepWithNext: true) { ctx, y in
            if alert {
                fillRect(ctx, MARGIN - 6, y, PAGE_W - MARGIN + 6, y + h, ALERT_BG)
            }
            sl.draw(ctx, x: MARGIN + (alert ? 10 : 0), y: y + 2)
        }
    }

    private static func kickerLineBlock(_ text: String, alert: Bool) -> Block {
        let sl = layout(text, width: CONTENT_W - (alert ? 12 : 0), size: 9, muted: false, bold: true)
        let h = sl.height + 4
        return Block(height: h) { ctx, y in
            sl.draw(ctx, x: MARGIN + (alert ? 10 : 0), y: y)
        }
    }

    private static func bulletBlock(_ text: String, alert: Bool) -> Block {
        let sl = layout(text, width: CONTENT_W - 18 - (alert ? 12 : 0), size: 9.5, muted: false)
        let h = sl.height + 3
        return Block(height: h) { ctx, y in
            fillCircle(ctx, MARGIN + (alert ? 14 : 4), y + 7, 2.2, PHOS)
            sl.draw(ctx, x: MARGIN + 14 + (alert ? 10 : 0), y: y)
        }
    }

    private static func pathKeyRow(_ n: Int, _ pile: SitPathPlot.Cluster) -> Block {
        let rest = pathKeyLine(n, pile).substringAfter("  ")
        let sl = layout(rest, width: CONTENT_W - 28, size: 9, muted: false)
        let h = Swift.max(16, sl.height + 4)
        return Block(height: h) { ctx, y in
            TextStyle(color: PHOS, size: 10, bold: true).drawText(ctx, "\(n)", MARGIN, y + 11)
            sl.draw(ctx, x: MARGIN + 22, y: y)
        }
    }

    private static func pathKeyGnssRow(_ pin: SitPathPlot.GnssPin) -> Block {
        let sl = layout(pin.keyLine(), width: CONTENT_W - 28, size: 9, muted: false)
        let h = Swift.max(18, sl.height + 4)
        return Block(height: h) { ctx, y in
            drawGnssMark(ctx, x: MARGIN + 7, y: y + 8, secondary: pin.secondary, radius: 5)
            sl.draw(ctx, x: MARGIN + 22, y: y)
        }
    }

    /// Same flight disc the map draws at the end of an advertised track.
    private static func pathKeyCraftRow(_ line: String) -> Block {
        let sl = layout(line, width: CONTENT_W - 28, size: 9, muted: false)
        let h = Swift.max(18, sl.height + 4)
        return Block(height: h) { ctx, y in
            drawClassMark(ctx, x: MARGIN + 7, y: y + 8, radius: 6.4)
            sl.draw(ctx, x: MARGIN + 22, y: y)
        }
    }

    private static func sectionHead(number: String, title: String, alert: Bool) -> Block {
        Block(height: 24, keepWithNext: true) { ctx, y in
            if alert {
                fillRect(ctx, MARGIN - 6, y, PAGE_W - MARGIN + 6, y + 22, ALERT_BG)
                fillRect(ctx, MARGIN - 6, y, MARGIN - 2, y + 22, ALERT_BAR)
            }
            let p = TextStyle(color: alert ? ALERT_BAR : PHOS, size: 11, bold: true)
            let label = number.isBlank ? title.uppercase() : "\(number)  \(title.uppercase())"
            p.drawText(ctx, label, MARGIN + (alert ? 10 : 0), y + 15)
            if !alert {
                line(ctx, MARGIN, y + 22, PAGE_W - MARGIN, y + 22, Pen(color: RULE, width: 0.6))
            }
        }
    }

    private static func bodyBlock(_ sl: TextLayout, alert: Bool) -> Block {
        let h = sl.height + 4
        let indent = alert ? 10.0 : 0.0
        return Block(height: h) { ctx, y in
            if alert {
                fillRect(ctx, MARGIN - 6, y, PAGE_W - MARGIN + 6, y + h, ALERT_BG)
                fillRect(ctx, MARGIN - 6, y, MARGIN - 2, y + h, ALERT_BAR)
            }
            sl.draw(ctx, x: MARGIN + indent, y: y)
        }
    }

    private static func attentionNoteBlock(_ hit: ExtraAttentionHit) -> Block {
        let innerW = CONTENT_W - 24
        let radio = layout(hit.radioLabel, width: innerW, size: 9, muted: false, bold: true)
        let note = layout(hit.note, width: innerW, size: 9.5, muted: false)
        let foot = layout("Pattern match, not identity. Not a safety finding.", width: innerW, size: 8, muted: true)
        let h = 22 + radio.height + 6 + note.height + 8 + foot.height + 12
        return Block(height: h) { ctx, y in
            let box = CGRect(x: MARGIN - 6, y: y, width: PAGE_W - 2 * MARGIN + 12, height: h - 4)
            fillRoundRect(ctx, box, 4, ALERT_BG)
            fillRect(ctx, box.minX, box.minY, box.minX + 4, box.maxY, ALERT_BAR)
            let kicker = TextStyle(color: ALERT_BAR, size: 8, bold: true, letterSpacing: 0.06)
            let label = "EXTRA ATTENTION  ·  \(hit.signature)".uppercase()
            kicker.drawText(ctx, label, MARGIN + 10, y + 14)
            var ty = y + 20
            radio.draw(ctx, x: MARGIN + 10, y: ty)
            ty += radio.height + 6
            note.draw(ctx, x: MARGIN + 10, y: ty)
            ty += note.height + 6
            foot.draw(ctx, x: MARGIN + 10, y: ty)
        }
    }

    private static func takeawayBlock(_ text: String) -> Block {
        let body = layout(text, width: CONTENT_W - 20, size: 10, muted: false, bold: true)
        let h = body.height + 32
        return Block(height: h) { ctx, y in
            let box = CGRect(x: MARGIN - 6, y: y, width: PAGE_W - 2 * MARGIN + 12, height: h - 4)
            fillRoundRect(ctx, box, 4, TAKE_BG)
            fillRect(ctx, box.minX, box.minY, box.minX + 4, box.maxY, PHOS)
            TextStyle(color: PHOS, size: 8, bold: true).drawText(ctx, "TAKEAWAY", MARGIN + 10, y + 14)
            body.draw(ctx, x: MARGIN + 10, y: y + 20)
        }
    }

    private static func stampChrome(_ ctx: CGContext, page: Int, total: Int, doc: DebriefDoc) {
        fillRect(ctx, 0, 0, PAGE_W, HEADER_H, HEADER_BG)
        let title = TextStyle(color: parseColor("#3DFF9A"), size: 11, bold: true, letterSpacing: 0.12)
        title.drawText(ctx, "FIELDWATCH", MARGIN, 26)
        let sub = TextStyle(color: parseColor("#C8D0D8"), size: 9, letterSpacing: 0.08)
        let label = doc.pdfKicker
        sub.drawText(ctx, label, PAGE_W - MARGIN - sub.measureText(label), 26)
        if doc.trackingAlert {
            fillRect(ctx, 0, HEADER_H, PAGE_W, HEADER_H + 3, ALERT_BAR)
        }
        line(ctx, MARGIN, PAGE_H - FOOTER_H, PAGE_W - MARGIN, PAGE_H - FOOTER_H, Pen(color: RULE, width: 0.6))
        let f = TextStyle(color: MUTED, size: 8)
        f.drawText(ctx, "Off Grid Pete LLC  ·  operationally sensitive", MARGIN, PAGE_H - 18)
        let pn = "\(page) / \(total)"
        f.drawText(ctx, pn, PAGE_W - MARGIN - f.measureText(pn), PAGE_H - 18)
    }

    private static func chunkText(_ text: String, width: Int, size: Double, muted: Bool) -> [TextLayout] {
        let full = layout(text, width: width, size: size, muted: muted)
        let maxH = USABLE - 8
        if full.height <= maxH { return [full] }
        var chunks: [TextLayout] = []
        var startLine = 0
        let ns = text as NSString
        while startLine < full.lineCount {
            var endLine = startLine
            var h = 0.0
            while endLine < full.lineCount {
                let lh = full.getLineBottom(endLine) - full.getLineTop(endLine)
                if h + lh > maxH && endLine > startLine { break }
                h += lh
                endLine += 1
            }
            if endLine == startLine { endLine += 1 }
            let start = full.getLineStart(startLine)
            let end = full.getLineEnd(endLine - 1)
            let piece = ns.substring(with: NSRange(location: start, length: end - start))
            chunks.append(layout(piece.trimEnd().ifEmpty(" "), width: width, size: size, muted: muted))
            startLine = endLine
        }
        return chunks.ifEmpty([full])
    }

    private static func layout(_ text: String, width: Int, size: Double, muted: Bool, bold: Bool = false) -> TextLayout {
        TextLayout(text: text, style: TextStyle(color: muted ? MUTED : INK, size: size, bold: bold), width: Double(width.coerceAtLeast(40)))
    }

    private static func removePrefix(_ s: String, _ prefix: String) -> String {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    // MARK: - Canvas / Paint stand-ins

    private static func parseColor(_ hex: String) -> CGColor {
        let v = Int(hex.drop(1), radix: 16) ?? 0
        return CGColor(srgbRed: Double((v >> 16) & 0xFF) / 255.0, green: Double((v >> 8) & 0xFF) / 255.0,
                       blue: Double(v & 0xFF) / 255.0, alpha: 1)
    }

    private static func argb(_ a: Int, _ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0, alpha: Double(a) / 255.0)
    }

    /// Stroke settings (Android `Paint` with STROKE style or `drawLine`).
    private struct Pen {
        var color: CGColor
        var width: Double = 0
        var roundCap = false
        var roundJoin = false
        var dash: [Double]? = nil
        /// Android `paint.alpha` override, 0…255.
        var alpha: Int? = nil

        func apply(_ ctx: CGContext) {
            let c = alpha.map { color.copy(alpha: Double($0) / 255.0) ?? color } ?? color
            ctx.setStrokeColor(c)
            ctx.setLineWidth(width)
            ctx.setLineCap(roundCap ? .round : .butt)
            ctx.setLineJoin(roundJoin ? .round : .miter)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) } else { ctx.setLineDash(phase: 0, lengths: []) }
        }
    }

    private static func line(_ ctx: CGContext, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ pen: Pen) {
        ctx.saveGState()
        pen.apply(ctx)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x0, y: y0))
        ctx.addLine(to: CGPoint(x: x1, y: y1))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokePath(_ ctx: CGContext, _ path: CGPath, _ pen: Pen) {
        ctx.saveGState()
        pen.apply(ctx)
        ctx.beginPath()
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func fillPath(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    private static func fillRect(_ ctx: CGContext, _ l: Double, _ t: Double, _ r: Double, _ b: Double, _ color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: l, y: t, width: r - l, height: b - t))
        ctx.restoreGState()
    }

    private static func strokeRect(_ ctx: CGContext, _ rect: CGRect, _ pen: Pen) {
        strokePath(ctx, CGPath(rect: rect, transform: nil), pen)
    }

    private static func roundRectPath(_ rect: CGRect, _ radius: Double) -> CGPath {
        let r = Swift.max(0, Swift.min(radius, Double(Swift.min(rect.width, rect.height)) / 2))
        return CGPath(roundedRect: rect.standardized, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func fillRoundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: Double, _ color: CGColor) {
        if rect.width <= 0 || rect.height <= 0 { return }
        fillPath(ctx, roundRectPath(rect, radius), color)
    }

    private static func strokeRoundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: Double, _ pen: Pen) {
        strokePath(ctx, roundRectPath(rect, radius), pen)
    }

    private static func circleRect(_ cx: Double, _ cy: Double, _ r: Double) -> CGRect {
        CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
    }

    private static func fillCircle(_ ctx: CGContext, _ cx: Double, _ cy: Double, _ r: Double, _ color: CGColor) {
        fillPath(ctx, CGPath(ellipseIn: circleRect(cx, cy, r), transform: nil), color)
    }

    private static func strokeCircle(_ ctx: CGContext, _ cx: Double, _ cy: Double, _ r: Double, _ pen: Pen) {
        strokePath(ctx, CGPath(ellipseIn: circleRect(cx, cy, r), transform: nil), pen)
    }

    // MARK: - Text (TextPaint / StaticLayout stand-ins)

    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var fontCache: [String: CTFont] = [:]

    fileprivate static func font(size: Double, bold: Bool) -> CTFont {
        let key = "\(size)|\(bold)"
        fontLock.lock()
        defer { fontLock.unlock() }
        if let f = fontCache[key] { return f }
        let f = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, CGFloat(size), nil)
        fontCache[key] = f
        return f
    }

    /// Android `TextPaint`: colour, size, bold sans, letter spacing (em), optional centre alignment.
    fileprivate struct TextStyle {
        var color: CGColor
        var size: Double
        var bold = false
        var letterSpacing = 0.0
        var center = false

        var font: CTFont { DebriefPdf.font(size: size, bold: bold) }

        func attributed(_ s: String) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            if letterSpacing != 0 {
                attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = NSNumber(value: letterSpacing * size)
            }
            return NSAttributedString(string: s, attributes: attrs)
        }

        func measureText(_ s: String) -> Double {
            if s.isEmpty { return 0 }
            let line = CTLineCreateWithAttributedString(attributed(s))
            return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        /// Android `canvas.drawText(text, x, baselineY, paint)` on the y-down page.
        func drawText(_ ctx: CGContext, _ s: String, _ x: Double, _ y: Double) {
            if s.isEmpty { return }
            let line = CTLineCreateWithAttributedString(attributed(s))
            var left = x
            if center { left -= Double(CTLineGetTypographicBounds(line, nil, nil, nil)) / 2 }
            DebriefPdf.drawLine(ctx, line, x: left, baseline: y)
        }
    }

    fileprivate static func drawLine(_ ctx: CGContext, _ line: CTLine, x: Double, baseline: Double) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Android `StaticLayout` (ALIGN_NORMAL, line spacing add 2 / mult 1, no include-pad).
    /// Line ranges are UTF-16 offsets into `text`, like Android's char offsets.
    fileprivate final class TextLayout {
        private struct Line {
            let start: Int
            let end: Int
            let top: Double
            let bottom: Double
            let ctLine: CTLine
        }

        private let lines: [Line]
        private let ascent: Double
        let height: Double
        var lineCount: Int { lines.count }

        init(text: String, style: TextStyle, width: Double) {
            let ns = text as NSString
            let font = style.font
            let asc = Double(CTFontGetAscent(font)).rounded()
            let base = asc + Double(CTFontGetDescent(font)).rounded()
            ascent = asc
            // (start, end-with-newline, CTLine)
            var raw: [(Int, Int, CTLine)] = []
            var paraStart = 0
            let total = ns.length
            repeat {
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: paraStart, length: total - paraStart))
                let paraEnd = nl.location == NSNotFound ? total : nl.location
                let hasNewline = nl.location != NSNotFound
                let paraText = ns.substring(with: NSRange(location: paraStart, length: paraEnd - paraStart))
                let attr = style.attributed(paraText)
                let ts = CTTypesetterCreateWithAttributedString(attr)
                let len = (paraText as NSString).length
                if len == 0 {
                    raw.append((paraStart, paraEnd + (hasNewline ? 1 : 0), CTTypesetterCreateLine(ts, CFRange(location: 0, length: 0))))
                } else {
                    var s = 0
                    while s < len {
                        var count = CTTypesetterSuggestLineBreak(ts, s, width)
                        if count <= 0 { count = 1 }
                        count = Swift.min(count, len - s)
                        let ct = CTTypesetterCreateLine(ts, CFRange(location: s, length: count))
                        let isParaLast = s + count >= len
                        raw.append((paraStart + s, paraStart + s + count + (isParaLast && hasNewline ? 1 : 0), ct))
                        s += count
                    }
                }
                paraStart = paraEnd + 1
                if !hasNewline { break }
            } while paraStart <= total
            var out: [Line] = []
            var top = 0.0
            for (i, r) in raw.enumerated() {
                // Android adds line-spacing extra to every line but the last.
                let h = base + (i == raw.count - 1 ? 0 : 2)
                out.append(Line(start: r.0, end: r.1, top: top, bottom: top + h, ctLine: r.2))
                top += h
            }
            lines = out
            height = top
        }

        func getLineTop(_ i: Int) -> Double { lines[i].top }
        func getLineBottom(_ i: Int) -> Double { lines[i].bottom }
        func getLineStart(_ i: Int) -> Int { lines[i].start }
        func getLineEnd(_ i: Int) -> Int { lines[i].end }

        /// Draw with the layout's top-left at (x, y).
        func draw(_ ctx: CGContext, x: Double, y: Double) {
            for l in lines {
                DebriefPdf.drawLine(ctx, l.ctLine, x: x, baseline: y + l.top + ascent)
            }
        }
    }

    // MARK: - Material glyphs (Icons.Outlined.Flight / Person, 24 × 24)

    private enum Glyphs {
        static let flight: CGPath = {
            let p = VectorPathBuilder()
            p.moveTo(21, 16)
            p.verticalLineToRelative(-2)
            p.lineToRelative(-8, -5)
            p.verticalLineTo(3.5)
            p.curveTo(13, 2.67, 12.33, 2, 11.5, 2)
            p.reflectiveCurveTo(10, 2.67, 10, 3.5)
            p.verticalLineTo(9)
            p.lineToRelative(-8, 5)
            p.verticalLineToRelative(2)
            p.lineToRelative(8, -2.5)
            p.verticalLineTo(19)
            p.lineToRelative(-2, 1.5)
            p.verticalLineTo(22)
            p.lineToRelative(3.5, -1)
            p.lineToRelative(3.5, 1)
            p.verticalLineToRelative(-1.5)
            p.lineTo(13, 19)
            p.verticalLineToRelative(-5.5)
            p.lineToRelative(8, 2.5)
            p.close()
            return p.path
        }()

        static let person: CGPath = {
            let p = VectorPathBuilder()
            p.moveTo(12, 6)
            p.curveToRelative(1.1, 0, 2, 0.9, 2, 2)
            p.reflectiveCurveToRelative(-0.9, 2, -2, 2)
            p.reflectiveCurveToRelative(-2, -0.9, -2, -2)
            p.reflectiveCurveToRelative(0.9, -2, 2, -2)
            p.moveTo(12, 16)
            p.curveToRelative(2.7, 0, 5.8, 1.29, 6, 2)
            p.horizontalLineTo(6)
            p.curveToRelative(0.23, -0.72, 3.31, -2, 6, -2)
            p.moveTo(12, 4)
            p.curveTo(9.79, 4, 8, 5.79, 8, 8)
            p.reflectiveCurveToRelative(1.79, 4, 4, 4)
            p.reflectiveCurveToRelative(4, -1.79, 4, -4)
            p.reflectiveCurveToRelative(-1.79, -4, -4, -4)
            p.close()
            p.moveTo(12, 14)
            p.curveToRelative(-2.67, 0, -8, 1.34, -8, 4)
            p.verticalLineToRelative(3)
            p.horizontalLineToRelative(16)
            p.verticalLineToRelative(-3)
            p.curveToRelative(0, -2.66, -5.33, -4, -8, -4)
            p.close()
            return p.path
        }()
    }

    /// Compose `PathBuilder` subset used by the Material icon sources.
    private final class VectorPathBuilder {
        let path = CGMutablePath()
        private var cx = 0.0, cy = 0.0
        private var startX = 0.0, startY = 0.0
        private var ctrlX = 0.0, ctrlY = 0.0
        private var lastWasCurve = false

        private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

        func moveTo(_ x: Double, _ y: Double) {
            path.move(to: pt(x, y)); cx = x; cy = y; startX = x; startY = y; lastWasCurve = false
        }
        func lineTo(_ x: Double, _ y: Double) { path.addLine(to: pt(x, y)); cx = x; cy = y; lastWasCurve = false }
        func lineToRelative(_ dx: Double, _ dy: Double) { lineTo(cx + dx, cy + dy) }
        func horizontalLineTo(_ x: Double) { lineTo(x, cy) }
        func horizontalLineToRelative(_ dx: Double) { lineTo(cx + dx, cy) }
        func verticalLineTo(_ y: Double) { lineTo(cx, y) }
        func verticalLineToRelative(_ dy: Double) { lineTo(cx, cy + dy) }
        func curveTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
            path.addCurve(to: pt(x3, y3), control1: pt(x1, y1), control2: pt(x2, y2))
            ctrlX = x2; ctrlY = y2; cx = x3; cy = y3; lastWasCurve = true
        }
        func curveToRelative(_ dx1: Double, _ dy1: Double, _ dx2: Double, _ dy2: Double, _ dx3: Double, _ dy3: Double) {
            curveTo(cx + dx1, cy + dy1, cx + dx2, cy + dy2, cx + dx3, cy + dy3)
        }
        func reflectiveCurveTo(_ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
            let x1 = lastWasCurve ? 2 * cx - ctrlX : cx
            let y1 = lastWasCurve ? 2 * cy - ctrlY : cy
            curveTo(x1, y1, x2, y2, x3, y3)
        }
        func reflectiveCurveToRelative(_ dx2: Double, _ dy2: Double, _ dx3: Double, _ dy3: Double) {
            reflectiveCurveTo(cx + dx2, cy + dy2, cx + dx3, cy + dy3)
        }
        func close() { path.closeSubpath(); cx = startX; cy = startY; lastWasCurve = false }
    }
}
