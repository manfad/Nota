import Foundation

/// A PowerPoint deck, read (SPEC "## Office documents and video"): a `.pptx`
/// unpacked into a scratch folder and written out once as one HTML page beside
/// its own `ppt/media`, a sheet per slide, each exactly the slide's size. The
/// Word tab's printer (`WebPDF.export(pageAt:to:paper:)`) puts that page on
/// paper the slide's size with no margin, which makes it a PDF a page a slide.
///
/// What a slide looks like is spread over four parts — the slide, its layout,
/// the layout's master and the master's theme — and a placeholder on a slide
/// says little more than "the title goes here": where, how big and in what
/// type all come from the layout and the master behind it. So the reading
/// folds that chain, the nearer part winning, the way `DOCXDocument` folds a
/// style's `basedOn` chain.
///
/// Drawn, in the slide's own stacking order: the background (a colour, a
/// gradient or a picture); the master's and the layout's own shapes behind the
/// slide's; shapes with their fill and outline (rectangles, rounded ones,
/// ellipses, triangles, diamonds, parallelograms, trapezoids, pentagons,
/// chevrons, lines, connectors drawn straight, and freeforms; any other preset
/// is drawn as its bounding box, so the text on it keeps its ground); text
/// with its insets, anchoring, autofit scale, bullets and numbers; pictures,
/// cropped; tables with their table style; and groups. The words stay words,
/// so the PDF can be searched and selected. Left out: charts, SmartArt,
/// embedded objects, Windows metafiles, arrowheads, effects (shadows, glow,
/// 3-D), speaker notes, comments, animations, transitions and hidden slides.
final class PPTXDocument {
    let fileURL: URL
    /// The folder the archive was unpacked into. It goes with the document.
    let unpackedURL: URL
    /// The page itself, at the folder's top so `ppt/media/…` resolves.
    let pageURL: URL
    /// Every slide's words, a line per paragraph and a blank line between
    /// slides — what ⇧⌘F searches.
    let plainText: String
    /// The slide, in points: the sheet each one is printed onto.
    let slideSize: CGSize
    /// Where that printout goes, beside the page, so it is cleared away with
    /// the rest of the folder. Nothing is there until somebody prints it.
    var pagesURL: URL { unpackedURL.appendingPathComponent("nota-slides.pdf") }

    private init(fileURL: URL, unpackedURL: URL, pageURL: URL, plainText: String,
                 slideSize: CGSize) {
        self.fileURL = fileURL
        self.unpackedURL = unpackedURL
        self.pageURL = pageURL
        self.plainText = plainText
        self.slideSize = slideSize
    }

    deinit {
        try? FileManager.default.removeItem(at: unpackedURL)
    }

    /// `nil` for anything that does not come apart into a deck: a zip with
    /// no `ppt/presentation.xml`, or one whose XML will not parse.
    static func open(_ fileURL: URL) -> PPTXDocument? {
        guard let folder = Unzip.toTemporaryFolder(fileURL, prefix: "Nota-PPTX") else {
            return nil
        }
        guard let converted = html(ofUnpacked: folder) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let page = folder.appendingPathComponent("nota-slides.html")
        do {
            try converted.html.write(to: page, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return PPTXDocument(
            fileURL: fileURL, unpackedURL: folder, pageURL: page, plainText: converted.text,
            slideSize: converted.slideSize
        )
    }

    /// The conversion on its own, for a folder already unpacked — the tests'
    /// way in, which builds a deck part by part rather than as a zip.
    static func html(ofUnpacked folder: URL) -> (html: String, text: String, slideSize: CGSize)? {
        guard var converter = PPTXConverter(root: folder) else { return nil }
        let converted = converter.convert()
        return (converted.html, converted.text, converter.slideSize)
    }
}

// MARK: - Properties

/// A length said one of two ways: a share of something (the line, the text's
/// size) or points.
enum PPTXMeasure {
    case percent(Double)
    case points(Double)

    /// In points, against text `size` points tall: a share of a line is a
    /// share of PowerPoint's single spacing, 1.2 times the size.
    func inPoints(size: Double) -> Double {
        switch self {
        case .percent(let share): return share * size * 1.2
        case .points(let value): return value
        }
    }
}

enum PPTXBullet {
    /// `buNone`: said, and said to be nothing — which is how a subtitle turns
    /// off the body style's bullets.
    case off
    case character(String)
    /// `buAutoNum`: `arabicPeriod`, `alphaLcParenR`, … from `start`.
    case number(scheme: String, start: Int)
}

/// A run's character formatting. Every field is optional: `nil` is "not said
/// here", so the chain from the master's text styles down to the run is
/// folded by letting the nearer one's said values win.
struct PPTXRunProps {
    /// Points.
    var size: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    /// `all`, `small` or `none`.
    var caps: String?
    /// A share of the size, up for a superscript and down for a subscript.
    var baseline: Double?
    /// Points between letters.
    var spacing: Double?
    /// CSS.
    var color: String?
    var font: String?

    mutating func merge(_ nearer: PPTXRunProps) {
        size = nearer.size ?? size
        bold = nearer.bold ?? bold
        italic = nearer.italic ?? italic
        underline = nearer.underline ?? underline
        strike = nearer.strike ?? strike
        caps = nearer.caps ?? caps
        baseline = nearer.baseline ?? baseline
        spacing = nearer.spacing ?? spacing
        color = nearer.color ?? color
        font = nearer.font ?? font
    }

    func merged(_ nearer: PPTXRunProps) -> PPTXRunProps {
        var copy = self
        copy.merge(nearer)
        return copy
    }

    /// The CSS for what is said, sizes scaled by the text box's autofit.
    func css(scale: Double) -> String {
        var parts: [String] = []
        if let bold { parts.append("font-weight:\(bold ? "bold" : "normal")") }
        if let italic { parts.append("font-style:\(italic ? "italic" : "normal")") }
        var lines: [String] = []
        if underline == true { lines.append("underline") }
        if strike == true { lines.append("line-through") }
        if !lines.isEmpty {
            parts.append("text-decoration:\(lines.joined(separator: " "))")
        } else if underline == false || strike == false {
            parts.append("text-decoration:none")
        }
        switch caps {
        case "all": parts.append("text-transform:uppercase")
        case "small": parts.append("font-variant:small-caps")
        case "none": parts.append("text-transform:none;font-variant:normal")
        default: break
        }
        if let size {
            // A superscript or subscript is drawn two thirds the size, as
            // PowerPoint draws it.
            let shrink = (baseline ?? 0) == 0 ? 1 : 2.0 / 3
            parts.append("font-size:\(PPTXConverter.number(size * scale * shrink))pt")
        }
        if let baseline, baseline != 0 {
            parts.append("vertical-align:\(baseline > 0 ? "super" : "sub")")
        }
        if let color { parts.append("color:\(color)") }
        if let font { parts.append("font-family:\(PPTXConverter.fontStack(font))") }
        if let spacing, spacing != 0 { parts.append("letter-spacing:\(PPTXConverter.number(spacing))pt") }
        return parts.joined(separator: ";")
    }
}

/// A paragraph's formatting, in points, on the same "nearer wins" rule, with
/// the level's own run defaults (`defRPr`) carried along.
struct PPTXParaProps {
    /// CSS `text-align`.
    var align: String?
    var marginLeft: Double?
    /// Where the first line starts against `marginLeft`: negative hangs the
    /// bullet out to the left of the text.
    var indent: Double?
    var bullet: PPTXBullet?
    /// `""` is `buFontTx` / `buClrTx`: the text's own, said in so many words.
    var bulletFont: String?
    var bulletColor: String?
    /// Against the text's size; `buSzTx` is 100%.
    var bulletSize: PPTXMeasure?
    var line: PPTXMeasure?
    var before: PPTXMeasure?
    var after: PPTXMeasure?
    var run = PPTXRunProps()

    mutating func merge(_ nearer: PPTXParaProps) {
        align = nearer.align ?? align
        marginLeft = nearer.marginLeft ?? marginLeft
        indent = nearer.indent ?? indent
        bullet = nearer.bullet ?? bullet
        bulletFont = nearer.bulletFont ?? bulletFont
        bulletColor = nearer.bulletColor ?? bulletColor
        bulletSize = nearer.bulletSize ?? bulletSize
        line = nearer.line ?? line
        before = nearer.before ?? before
        after = nearer.after ?? after
        run.merge(nearer.run)
    }
}

/// A list style — a master's `titleStyle`, a placeholder's `lstStyle` — is a
/// paragraph's formatting for each of the nine outline levels.
struct PPTXListStyle {
    var levels = Array(repeating: PPTXParaProps(), count: 9)

    mutating func merge(_ nearer: PPTXListStyle) {
        for index in levels.indices { levels[index].merge(nearer.levels[index]) }
    }

    /// The same run formatting laid over every level: a shape's `fontRef`, a
    /// table style's cell text.
    mutating func mergeRuns(_ nearer: PPTXRunProps) {
        for index in levels.indices { levels[index].run.merge(nearer) }
    }
}

/// A text box's own settings (`bodyPr`), folded the same way.
struct PPTXBodyProps {
    /// Points, inside the shape's edges.
    var left: Double?
    var top: Double?
    var right: Double?
    var bottom: Double?
    /// `t`, `ctr` or `b`.
    var anchor: String?
    var wrap: Bool?
    /// `vert`, `vert270`, `eaVert`, … for text set on its side.
    var vertical: String?
    /// `normAutofit`'s shrink: the share the text's sizes are drawn at, and
    /// the share taken off its line spacing.
    var fontScale: Double?
    var lineReduction: Double?

    mutating func merge(_ nearer: PPTXBodyProps) {
        left = nearer.left ?? left
        top = nearer.top ?? top
        right = nearer.right ?? right
        bottom = nearer.bottom ?? bottom
        anchor = nearer.anchor ?? anchor
        wrap = nearer.wrap ?? wrap
        vertical = nearer.vertical ?? vertical
        fontScale = nearer.fontScale ?? fontScale
        lineReduction = nearer.lineReduction ?? lineReduction
    }
}

// MARK: - Colours, fills and lines

/// A colour as DrawingML ends up meaning it: red, green, blue and alpha from
/// 0 to 1, after the theme has been looked up and the modifiers applied.
private struct PPTXColor {
    var red: Double
    var green: Double
    var blue: Double
    var alpha = 1.0

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double) {
        self.alpha = alpha
        guard saturation > 0 else {
            red = lightness
            green = lightness
            blue = lightness
            return
        }
        let q = lightness < 0.5
            ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        red = channel(hue + 1.0 / 3)
        green = channel(hue)
        blue = channel(hue - 1.0 / 3)
    }

    private var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        if high == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if high == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        return (hue / 6, saturation, lightness)
    }

    /// The modifiers a colour element carries (`lumMod`, `tint`, `alpha`, …),
    /// in the order they are written. The ones not here (hue shifts, gamma,
    /// inversion) are rare enough in a deck to leave the colour as it is.
    mutating func apply(_ modifiers: [XMLElement]) {
        for modifier in modifiers {
            guard let value = modifier.attr("val").flatMap(PPTXConverter.fraction) else { continue }
            switch modifier.local {
            case "lumMod", "lumOff", "satMod", "satOff":
                var (hue, saturation, lightness) = hsl
                switch modifier.local {
                case "lumMod": lightness *= value
                case "lumOff": lightness += value
                case "satMod": saturation *= value
                default: saturation += value
                }
                self = PPTXColor(hue: hue, saturation: min(max(saturation, 0), 1),
                                 lightness: min(max(lightness, 0), 1), alpha: alpha)
            case "tint":
                red = 1 - (1 - red) * value
                green = 1 - (1 - green) * value
                blue = 1 - (1 - blue) * value
            case "shade":
                red *= value
                green *= value
                blue *= value
            case "alpha":
                alpha = value
            case "alphaMod":
                alpha *= value
            default:
                break
            }
        }
    }

    var css: String {
        func byte(_ channel: Double) -> Int { Int((min(max(channel, 0), 1) * 255).rounded()) }
        if alpha >= 0.999 {
            return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
        }
        return "rgba(\(byte(red)),\(byte(green)),\(byte(blue)),\(PPTXConverter.number(alpha)))"
    }
}

private enum PPTXFill {
    case clear
    case solid(PPTXColor)
    /// Stops from 0 to 1; the angle clockwise from left-to-right, in degrees.
    case gradient([(position: Double, color: PPTXColor)], angle: Double, radial: Bool)
    /// A picture's path in the package, stretched over the shape.
    case picture(String)

    /// The one colour that stands for it where only one can be drawn: a
    /// table cell, a slide's edge, a line.
    var color: PPTXColor? {
        switch self {
        case .solid(let color): return color
        case .gradient(let stops, _, _): return stops.first?.color
        default: return nil
        }
    }
}

private struct PPTXLine {
    var fill: PPTXFill?
    /// Points.
    var width: Double?
    /// `prstDash`: `dash`, `sysDot`, …
    var dash: String?

    mutating func merge(_ nearer: PPTXLine) {
        fill = nearer.fill ?? fill
        width = nearer.width ?? width
        dash = nearer.dash ?? dash
    }

    /// A table cell's border side.
    var cssBorder: String {
        guard let color = fill?.color else { return "none" }
        return "\(PPTXConverter.number(width ?? 0.75))pt solid \(color.css)"
    }
}

// MARK: - Parts

/// A theme, as much of it as a slide draws with: the twelve colours, the
/// heading and body typefaces, and the style matrix's fills and lines that a
/// shape's `p:style` points into by number.
private struct PPTXTheme {
    var colors: [String: PPTXColor] = [:]
    var majorFont = "Calibri"
    var minorFont = "Calibri"
    var fills: [XMLElement] = []
    var backgrounds: [XMLElement] = []
    var lines: [XMLElement] = []
}

/// Which placeholder a shape is: its `type` (`obj` when unsaid) and `idx`.
private struct PPTXPlaceholder {
    let type: String
    let idx: String?

    init?(of element: XMLElement) {
        guard let properties = element.elementChildren.first(where: { $0.local.hasPrefix("nv") }),
              let ph = properties.child("nvPr")?.child("ph") else { return nil }
        type = ph.attr("type") ?? "obj"
        idx = ph.attr("idx")
    }

    /// The family a master keeps text styles and placeholders by: a title,
    /// a body, or one of the master's own (date, footer, slide number).
    var kind: String {
        switch type {
        case "title", "ctrTitle": return "title"
        case "dt", "ftr", "sldNum", "hdr": return type
        default: return "body"
        }
    }
}

/// A slide, a layout or a master: its XML, its relationships, and the
/// placeholders on it.
private struct PPTXPart {
    let root: XMLElement
    let rels: OfficeRelationships
    /// A slide's placeholders are drawn; a layout's or a master's are only
    /// prompts for a slide to fill.
    let isSlide: Bool
    let placeholders: [(placeholder: PPTXPlaceholder, shape: XMLElement)]

    init(root: XMLElement, rels: OfficeRelationships, isSlide: Bool) {
        self.root = root
        self.rels = rels
        self.isSlide = isSlide
        placeholders = (root.child("cSld")?.child("spTree")?.elementChildren ?? []).compactMap {
            element in PPTXPlaceholder(of: element).map { (placeholder: $0, shape: element) }
        }
    }

    var tree: XMLElement? { root.child("cSld")?.child("spTree") }

    /// The placeholder here a nearer one stands in front of: by index first
    /// when asked (a slide's body is its layout's `idx="1"`), then by type,
    /// then by family (a layout's `subTitle` is the master's body).
    func counterpart(of placeholder: PPTXPlaceholder, byIndex: Bool) -> XMLElement? {
        if byIndex, placeholder.kind != "title", let idx = placeholder.idx,
           let found = placeholders.first(where: { $0.placeholder.idx == idx }) {
            return found.shape
        }
        if let found = placeholders.first(where: { $0.placeholder.type == placeholder.type }) {
            return found.shape
        }
        return placeholders.first { $0.placeholder.kind == placeholder.kind }?.shape
    }
}

private struct PPTXMaster {
    let part: PPTXPart
    let theme: PPTXTheme
    let colorMap: [String: String]
    /// The master's text styles, each already folded over the presentation's
    /// defaults.
    let titleStyle: PPTXListStyle
    let bodyStyle: PPTXListStyle
    let otherStyle: PPTXListStyle
}

/// A shape and the part it was read from, so a picture it points at is
/// looked up in the right `.rels`.
private struct PPTXSource {
    let element: XMLElement
    let part: PPTXPart
}

/// A shape's box, in points, inside whatever holds it.
private struct PPTXFrame {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Degrees, clockwise, about the box's centre.
    var rotation: Double = 0
    var flipH = false
    var flipV = false

    var css: String {
        var css = "left:\(PPTXConverter.number(x))pt;top:\(PPTXConverter.number(y))pt;"
            + "width:\(PPTXConverter.number(width))pt;height:\(PPTXConverter.number(height))pt"
        if rotation != 0 { css += ";transform:rotate(\(PPTXConverter.number(rotation))deg)" }
        return css
    }
}

/// Where an `xfrm` lands: the slide's own space (EMU from its top left), or
/// a group's, whose children are written in a space of the group's choosing
/// and scaled into its box.
private struct PPTXSpace {
    /// Points per unit, and the unit at the space's top left.
    var scaleX = 1 / 12_700.0
    var scaleY = 1 / 12_700.0
    var originX = 0.0
    var originY = 0.0

    static let slide = PPTXSpace()

    private static func pair(_ element: XMLElement?, _ a: String, _ b: String) -> (Double, Double) {
        (element?.attr(a).flatMap(Double.init) ?? 0, element?.attr(b).flatMap(Double.init) ?? 0)
    }

    func frame(_ xfrm: XMLElement) -> PPTXFrame {
        let (x, y) = Self.pair(xfrm.child("off"), "x", "y")
        let (cx, cy) = Self.pair(xfrm.child("ext"), "cx", "cy")
        var frame = PPTXFrame(x: (x - originX) * scaleX, y: (y - originY) * scaleY,
                              width: cx * scaleX, height: cy * scaleY)
        frame.rotation = (xfrm.attr("rot").flatMap(Double.init) ?? 0) / 60_000
        frame.flipH = PPTXConverter.isOn(xfrm.attr("flipH"))
        frame.flipV = PPTXConverter.isOn(xfrm.attr("flipV"))
        return frame
    }

    /// The space a group's children are written in, measured inside the
    /// group's own box.
    func inside(_ xfrm: XMLElement) -> PPTXSpace {
        let (cx, cy) = Self.pair(xfrm.child("ext"), "cx", "cy")
        let (childX, childY) = Self.pair(xfrm.child("chOff"), "x", "y")
        let (childCX, childCY) = Self.pair(xfrm.child("chExt"), "cx", "cy")
        return PPTXSpace(
            scaleX: childCX > 0 ? scaleX * cx / childCX : scaleX,
            scaleY: childCY > 0 ? scaleY * cy / childCY : scaleY,
            originX: childX, originY: childY
        )
    }
}

// MARK: - The conversion

/// One pass over the deck, slide by slide, with the presentation, its
/// masters and layouts read as they are first needed. A struct with the
/// walk's state in it — the slide being drawn, its master's theme — so the
/// whole conversion is one value that is used once.
private struct PPTXConverter {
    let root: URL
    private(set) var slideSize = CGSize(width: 960, height: 540)
    var slidePaths: [String] = []
    var firstSlideNumber = 1
    var defaultTextStyle: XMLElement?
    var tableStyles: [String: XMLElement] = [:]
    var title: String?
    var layouts: [String: PPTXPart] = [:]
    var masters: [String: PPTXMaster] = [:]

    // The slide being drawn.
    var layout: PPTXPart?
    var master: PPTXMaster?
    var theme = PPTXTheme()
    var colorMap = PPTXConverter.defaultColorMap
    var slideNumber = 1
    var lines: [String] = []
    /// What a shape inside a group fills with when it says `grpFill`.
    var groupFill: PPTXFill?
    /// Gradients and clips are SVG definitions, which want ids unique to the
    /// page.
    var paints = 0

    static let defaultColorMap = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"]

    init?(root: URL) {
        self.root = root
        guard let presentation = Self.xml(root, "ppt/presentation.xml") else { return nil }
        let rels = OfficeRelationships(
            relsAt: root.appendingPathComponent("ppt/_rels/presentation.xml.rels"), ownerFolder: "ppt/"
        )
        for slide in presentation.child("sldIdLst")?.children(named: "sldId") ?? [] {
            if let id = Self.relationshipID(slide), let target = rels[id], !target.isExternal {
                slidePaths.append(target.path)
            }
        }
        if let size = presentation.child("sldSz"),
           let cx = size.attr("cx").flatMap(Double.init), let cy = size.attr("cy").flatMap(Double.init),
           cx > 0, cy > 0 {
            slideSize = CGSize(width: cx / 12_700, height: cy / 12_700)
        }
        firstSlideNumber = presentation.attr("firstSlideNum").flatMap(Int.init) ?? 1
        defaultTextStyle = presentation.child("defaultTextStyle")
        for style in Self.xml(root, "ppt/tableStyles.xml")?.children(named: "tblStyle") ?? [] {
            if let id = style.attr("styleId") { tableStyles[id] = style }
        }
        if tableStyles[Self.mediumStyle2ID] == nil,
           let builtIn = try? XMLDocument(xmlString: Self.mediumStyle2, options: [])
            .rootElement() {
            tableStyles[Self.mediumStyle2ID] = builtIn
        }
        if let value = Self.xml(root, "docProps/core.xml")?.child("title")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            title = value
        }
    }

    // MARK: Parts

    private static func xml(_ root: URL, _ path: String) -> XMLElement? {
        let url = root.appendingPathComponent(path)
        return (try? XMLDocument(contentsOf: url, options: [.nodePreserveWhitespace]))?.rootElement()
    }

    /// `r:id`, not the plain `id` beside it on a `sldId`.
    private static func relationshipID(_ element: XMLElement) -> String? {
        (element.attributes ?? []).first { $0.local == "id" && !($0.prefix ?? "").isEmpty }?
            .stringValue
    }

    private func part(_ path: String, isSlide: Bool) -> PPTXPart? {
        guard let element = Self.xml(root, path) else { return nil }
        let folder = (path as NSString).deletingLastPathComponent + "/"
        let name = (path as NSString).lastPathComponent
        let rels = OfficeRelationships(
            relsAt: root.appendingPathComponent(folder + "_rels/" + name + ".rels"), ownerFolder: folder
        )
        return PPTXPart(root: element, rels: rels, isSlide: isSlide)
    }

    /// The one part of a kind a part points at: a slide's layout, a
    /// layout's master, a master's theme.
    private func related(_ part: PPTXPart, _ folder: String) -> String? {
        part.rels.targets.values.first { !$0.isExternal && $0.path.contains(folder) }?.path
    }

    private mutating func loadLayout(_ path: String) -> PPTXPart? {
        if let cached = layouts[path] { return cached }
        let layout = part(path, isSlide: false)
        layouts[path] = layout
        return layout
    }

    private mutating func loadMaster(_ path: String) -> PPTXMaster? {
        if let cached = masters[path] { return cached }
        guard let part = part(path, isSlide: false) else { return nil }
        // The master's text styles are read in its own theme's colours.
        theme = related(part, "theme/").map(readTheme) ?? PPTXTheme()
        colorMap = Self.defaultColorMap
        for attribute in part.root.child("clrMap")?.attributes ?? [] {
            if let value = attribute.stringValue { colorMap[attribute.local] = value }
        }
        var base = PPTXListStyle()
        base.mergeRuns(PPTXRunProps(size: 18, color: schemeColor("tx1", placeholder: nil)?.css,
                                    font: theme.minorFont))
        base.merge(listStyle(defaultTextStyle))
        let styles = part.root.child("txStyles")
        func style(_ name: String) -> PPTXListStyle {
            var style = base
            style.merge(listStyle(styles?.child(name)))
            return style
        }
        let master = PPTXMaster(
            part: part, theme: theme, colorMap: colorMap, titleStyle: style("titleStyle"),
            bodyStyle: style("bodyStyle"), otherStyle: style("otherStyle")
        )
        masters[path] = master
        return master
    }

    private func readTheme(_ path: String) -> PPTXTheme {
        var theme = PPTXTheme()
        guard let elements = Self.xml(root, path)?.child("themeElements") else { return theme }
        for entry in elements.child("clrScheme")?.elementChildren ?? [] {
            if let hex = entry.child("srgbClr")?.attr("val"), let color = PPTXColor(hex: hex) {
                theme.colors[entry.local] = color
            } else if let system = entry.child("sysClr") {
                let hex = system.attr("lastClr") ?? (system.attr("val") == "window" ? "FFFFFF" : "000000")
                theme.colors[entry.local] = PPTXColor(hex: hex)
            }
        }
        let fonts = elements.child("fontScheme")
        if let face = fonts?.child("majorFont")?.child("latin")?.attr("typeface"), !face.isEmpty {
            theme.majorFont = face
        }
        if let face = fonts?.child("minorFont")?.child("latin")?.attr("typeface"), !face.isEmpty {
            theme.minorFont = face
        }
        let matrix = elements.child("fmtScheme")
        theme.fills = matrix?.child("fillStyleLst")?.elementChildren ?? []
        theme.backgrounds = matrix?.child("bgFillStyleLst")?.elementChildren ?? []
        theme.lines = matrix?.child("lnStyleLst")?.children(named: "ln") ?? []
        return theme
    }

    // MARK: Reading colours and fills

    private func schemeColor(_ name: String, placeholder: PPTXColor?) -> PPTXColor? {
        if name == "phClr" { return placeholder }
        return theme.colors[colorMap[name] ?? name]
    }

    private static let colorElements: Set = [
        "srgbClr", "schemeClr", "sysClr", "prstClr", "scrgbClr", "hslClr",
    ]

    /// The colour a fill, a run or a reference carries as one of its
    /// children. `phClr` — the style matrix's "whatever colour pointed here"
    /// — is `placeholder`.
    private func color(in parent: XMLElement?, placeholder: PPTXColor? = nil) -> PPTXColor? {
        guard let element = parent?.elementChildren.first(where: {
            Self.colorElements.contains($0.local)
        }) else { return nil }
        var base: PPTXColor?
        switch element.local {
        case "srgbClr":
            base = element.attr("val").flatMap(PPTXColor.init(hex:))
        case "schemeClr":
            base = element.attr("val").flatMap { schemeColor($0, placeholder: placeholder) }
        case "sysClr":
            base = PPTXColor(hex: element.attr("lastClr")
                ?? (element.attr("val") == "window" ? "FFFFFF" : "000000"))
        case "prstClr":
            base = element.attr("val").flatMap { Self.presetColors[$0] }.flatMap(PPTXColor.init(hex:))
        case "scrgbClr":
            // Linear light, as a share each; made sRGB.
            func channel(_ name: String) -> Double {
                let linear = element.attr(name).flatMap(Self.fraction) ?? 0
                return linear <= 0.003_130_8 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
            }
            base = PPTXColor(red: channel("r"), green: channel("g"), blue: channel("b"))
        case "hslClr":
            base = PPTXColor(
                hue: (element.attr("hue").flatMap(Double.init) ?? 0) / 21_600_000,
                saturation: element.attr("sat").flatMap(Self.fraction) ?? 0,
                lightness: element.attr("lum").flatMap(Self.fraction) ?? 0, alpha: 1
            )
        default:
            break
        }
        guard var color = base else { return nil }
        color.apply(element.elementChildren)
        return color
    }

    private static let presetColors: [String: String] = [
        "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF",
        "yellow": "FFFF00", "cyan": "00FFFF", "magenta": "FF00FF", "gray": "808080",
        "grey": "808080", "darkGray": "A9A9A9", "lightGray": "D3D3D3", "orange": "FFA500",
        "purple": "800080", "navy": "000080", "silver": "C0C0C0", "maroon": "800000",
    ]

    /// The first fill a `spPr`, a `bgPr`, an `ln` or a cell says it has.
    private func fill(in parent: XMLElement?, part: PPTXPart?, placeholder: PPTXColor? = nil) -> PPTXFill? {
        for element in parent?.elementChildren ?? [] {
            if let fill = fill(element, part: part, placeholder: placeholder) { return fill }
        }
        return nil
    }

    private func fill(_ element: XMLElement, part: PPTXPart?, placeholder: PPTXColor?) -> PPTXFill? {
        switch element.local {
        case "noFill":
            return .clear
        case "solidFill":
            return color(in: element, placeholder: placeholder).map(PPTXFill.solid)
        case "gradFill":
            let stops = (element.child("gsLst")?.children(named: "gs") ?? []).compactMap {
                stop -> (position: Double, color: PPTXColor)? in
                guard let color = color(in: stop, placeholder: placeholder) else { return nil }
                return (stop.attr("pos").flatMap(Self.fraction) ?? 0, color)
            }.sorted { $0.position < $1.position }
            guard !stops.isEmpty else { return nil }
            let angle = (element.child("lin")?.attr("ang").flatMap(Double.init) ?? 0) / 60_000
            return .gradient(stops, angle: angle, radial: element.child("path") != nil)
        case "blipFill":
            guard let part, let id = element.child("blip")?.attr("embed"),
                  let target = part.rels[id], !target.isExternal, Self.isDrawable(target.path)
            else { return nil }
            return .picture(target.path)
        case "pattFill":
            return color(in: element.child("fgClr"), placeholder: placeholder).map(PPTXFill.solid)
        case "grpFill":
            return groupFill
        default:
            return nil
        }
    }

    /// A shape's `fillRef` or a background's `bgRef`: an entry in the theme's
    /// style matrix, painted in the colour the reference carries.
    private func styleFill(_ reference: XMLElement) -> PPTXFill? {
        let index = reference.attr("idx").flatMap(Int.init) ?? 0
        let tint = color(in: reference)
        guard index > 0 else { return .clear }
        let list = index >= 1_001 ? theme.backgrounds : theme.fills
        let position = index >= 1_001 ? index - 1_001 : index - 1
        if position < list.count, let fill = fill(list[position], part: nil, placeholder: tint) {
            return fill
        }
        return tint.map(PPTXFill.solid)
    }

    private func line(_ ln: XMLElement?, part: PPTXPart?, placeholder: PPTXColor? = nil) -> PPTXLine {
        var line = PPTXLine()
        guard let ln else { return line }
        line.width = ln.attr("w").flatMap(Double.init).map { $0 / 12_700 }
        line.fill = fill(in: ln, part: part, placeholder: placeholder)
        line.dash = ln.val(of: "prstDash")
        return line
    }

    private func styleLine(_ reference: XMLElement) -> PPTXLine {
        let index = reference.attr("idx").flatMap(Int.init) ?? 0
        guard index > 0 else { return PPTXLine() }
        let tint = color(in: reference)
        if index - 1 < theme.lines.count {
            return line(theme.lines[index - 1], part: nil, placeholder: tint)
        }
        return PPTXLine(fill: tint.map(PPTXFill.solid), width: 0.75)
    }

    // MARK: Reading text properties

    /// `+mj-lt`, `+mn-ea`, … are the theme's heading and body typefaces.
    private func typeface(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if name.hasPrefix("+mj") { return theme.majorFont }
        if name.hasPrefix("+mn") { return theme.minorFont }
        return name
    }

    private func runProps(_ rPr: XMLElement?) -> PPTXRunProps {
        var props = PPTXRunProps()
        guard let rPr else { return props }
        props.size = rPr.attr("sz").flatMap(Double.init).map { $0 / 100 }
        props.bold = rPr.attr("b").map(Self.isOn)
        props.italic = rPr.attr("i").map(Self.isOn)
        if let underline = rPr.attr("u") { props.underline = underline != "none" }
        if let strike = rPr.attr("strike") { props.strike = strike != "noStrike" }
        props.caps = rPr.attr("cap")
        props.baseline = rPr.attr("baseline").flatMap(Self.fraction)
        props.spacing = rPr.attr("spc").flatMap(Double.init).map { $0 / 100 }
        if let fill = rPr.child("solidFill") ?? rPr.child("gradFill"),
           let color = self.fill(fill, part: nil, placeholder: nil)?.color {
            props.color = color.css
        }
        props.font = typeface(rPr.child("latin")?.attr("typeface"))
            ?? typeface(rPr.child("ea")?.attr("typeface"))
        // A link is drawn the way PowerPoint draws one: the theme's link
        // colour, underlined. It is not a link on the printed page.
        if rPr.child("hlinkClick") != nil {
            props.underline = true
            if let link = schemeColor("hlink", placeholder: nil) { props.color = link.css }
        }
        return props
    }

    private func paraProps(_ pPr: XMLElement?) -> PPTXParaProps {
        var props = PPTXParaProps()
        guard let pPr else { return props }
        if let align = pPr.attr("algn") {
            switch align {
            case "ctr": props.align = "center"
            case "r": props.align = "right"
            case "just", "justLow", "dist", "thaiDist": props.align = "justify"
            default: props.align = "left"
            }
        }
        props.marginLeft = pPr.attr("marL").flatMap(Double.init).map { $0 / 12_700 }
        props.indent = pPr.attr("indent").flatMap(Double.init).map { $0 / 12_700 }
        props.line = measure(pPr.child("lnSpc"))
        props.before = measure(pPr.child("spcBef"))
        props.after = measure(pPr.child("spcAft"))
        if pPr.child("buNone") != nil {
            props.bullet = .off
        } else if let character = pPr.child("buChar")?.attr("char") {
            props.bullet = .character(character)
        } else if let number = pPr.child("buAutoNum") {
            props.bullet = .number(scheme: number.attr("type") ?? "arabicPeriod",
                                   start: number.attr("startAt").flatMap(Int.init) ?? 1)
        } else if pPr.child("buBlip") != nil {
            // A picture bullet; a dot stands in for it.
            props.bullet = .character("•")
        }
        if pPr.child("buFontTx") != nil {
            props.bulletFont = ""
        } else if let face = pPr.child("buFont")?.attr("typeface") {
            props.bulletFont = typeface(face) ?? face
        }
        if pPr.child("buClrTx") != nil {
            props.bulletColor = ""
        } else if let color = color(in: pPr.child("buClr")) {
            props.bulletColor = color.css
        }
        if pPr.child("buSzTx") != nil {
            props.bulletSize = .percent(1)
        } else if let share = pPr.child("buSzPct")?.attr("val").flatMap(Self.fraction) {
            props.bulletSize = .percent(share)
        } else if let points = pPr.child("buSzPts")?.attr("val").flatMap(Double.init) {
            props.bulletSize = .points(points / 100)
        }
        if let defaults = pPr.child("defRPr") { props.run = runProps(defaults) }
        return props
    }

    private func measure(_ spacing: XMLElement?) -> PPTXMeasure? {
        if let share = spacing?.child("spcPct")?.attr("val").flatMap(Self.fraction) {
            return .percent(share)
        }
        if let points = spacing?.child("spcPts")?.attr("val").flatMap(Double.init) {
            return .points(points / 100)
        }
        return nil
    }

    /// A `lstStyle` or a master's text style: `defPPr` under every level,
    /// then each `lvlNpPr`.
    private func listStyle(_ element: XMLElement?) -> PPTXListStyle {
        var style = PPTXListStyle()
        guard let element else { return style }
        let shared = paraProps(element.child("defPPr"))
        for index in style.levels.indices {
            var level = shared
            level.merge(paraProps(element.child("lvl\(index + 1)pPr")))
            style.levels[index] = level
        }
        return style
    }

    private func bodyProps(_ bodyPr: XMLElement?) -> PPTXBodyProps {
        var props = PPTXBodyProps()
        guard let bodyPr else { return props }
        func inset(_ name: String) -> Double? {
            bodyPr.attr(name).flatMap(Double.init).map { $0 / 12_700 }
        }
        props.left = inset("lIns")
        props.top = inset("tIns")
        props.right = inset("rIns")
        props.bottom = inset("bIns")
        props.anchor = bodyPr.attr("anchor")
        props.wrap = bodyPr.attr("wrap").map { $0 != "none" }
        props.vertical = bodyPr.attr("vert")
        if let shrink = bodyPr.child("normAutofit") {
            props.fontScale = shrink.attr("fontScale").flatMap(Self.fraction) ?? 1
            props.lineReduction = shrink.attr("lnSpcReduction").flatMap(Self.fraction) ?? 0
        } else if bodyPr.child("noAutofit") != nil || bodyPr.child("spAutoFit") != nil {
            props.fontScale = 1
            props.lineReduction = 0
        }
        return props
    }

    // MARK: The walk

    mutating func convert() -> (html: String, text: String) {
        var sheets: [String] = []
        var texts: [String] = []
        for (index, path) in slidePaths.enumerated() {
            // A hidden slide still has its number; the next one shown keeps its own.
            guard let sheet = slide(path, number: firstSlideNumber + index) else { continue }
            sheets.append(sheet)
            texts.append(lines.joined(separator: "\n"))
        }
        return (page(sheets.joined()), texts.joined(separator: "\n\n"))
    }

    private mutating func slide(_ path: String, number: Int) -> String? {
        guard let slide = part(path, isSlide: true),
              slide.root.attr("show").map(Self.isOn) ?? true else { return nil }
        layout = related(slide, "slideLayouts/").flatMap { loadLayout($0) }
        master = layout.flatMap { related($0, "slideMasters/") }.flatMap { loadMaster($0) }
        theme = master?.theme ?? PPTXTheme()
        colorMap = master?.colorMap ?? Self.defaultColorMap
        for part in [layout, slide].compactMap({ $0 }) {
            guard let override = part.root.child("clrMapOvr")?.child("overrideClrMapping") else {
                continue
            }
            for attribute in override.attributes ?? [] {
                if let value = attribute.stringValue { colorMap[attribute.local] = value }
            }
        }
        slideNumber = number
        lines = []
        groupFill = nil

        let ground = background(slide)
        var content = ground.html
        // `showMasterSp="0"` on a slide hides what its layout and master draw;
        // on a layout, what its master draws.
        let showsMaster = slide.root.attr("showMasterSp").map(Self.isOn) ?? true
        if showsMaster, layout?.root.attr("showMasterSp").map(Self.isOn) ?? true,
           let master, let tree = master.part.tree {
            content += elements(of: tree, part: master.part, space: .slide)
        }
        if showsMaster, let layout, let tree = layout.tree {
            content += elements(of: tree, part: layout, space: .slide)
        }
        if let tree = slide.tree {
            content += elements(of: tree, part: slide, space: .slide)
        }
        // The sheet is a hair shorter than the paper (see `page`); a solid
        // ground is carried over that hair by a shadow, which takes no room.
        let edge = ground.edge.map { " style=\"box-shadow:0 1px 0 0 \($0.css)\"" } ?? ""
        return "<div class=\"slide\"\(edge)>\(content)</div>"
    }

    /// The slide's ground: its own, else its layout's, else its master's;
    /// white when none says.
    private mutating func background(_ slide: PPTXPart) -> (html: String, edge: PPTXColor?) {
        var ground = PPTXFill.solid(PPTXColor(red: 1, green: 1, blue: 1))
        for part in [slide, layout, master?.part].compactMap({ $0 }) {
            guard let bg = part.root.child("cSld")?.child("bg") else { continue }
            if let found = fill(in: bg.child("bgPr"), part: part) {
                ground = found
                break
            }
            if let reference = bg.child("bgRef"), let found = styleFill(reference) {
                ground = found
                break
            }
        }
        let width = Double(slideSize.width)
        let height = Double(slideSize.height)
        let drawn = drawing(Self.rectangle(width, height), width: width, height: height,
                            fill: ground, line: PPTXLine())
        var edge: PPTXColor?
        if case .solid(let color) = ground { edge = color }
        let frame = PPTXFrame(x: 0, y: 0, width: width, height: height)
        return ("<div class=\"shape\" style=\"\(frame.css)\">\(drawn)</div>", edge)
    }

    /// A shape tree's drawings, in its order — which is their stacking order.
    private mutating func elements(of tree: XMLElement, part: PPTXPart, space: PPTXSpace) -> String {
        var out = ""
        for element in tree.elementChildren {
            switch element.local {
            case "sp", "cxnSp", "pic", "graphicFrame":
                if !part.isSlide, PPTXPlaceholder(of: element) != nil { continue }
                switch element.local {
                case "pic": out += picture(element, part: part, space: space)
                case "graphicFrame": out += graphicFrame(element, part: part, space: space)
                default: out += shape(element, part: part, space: space)
                }
            case "grpSp":
                out += group(element, part: part, space: space)
            case "AlternateContent":
                // The newer form when it holds anything drawable, else the
                // older one written beside it for readers like this.
                let drawable: Set = ["sp", "cxnSp", "pic", "graphicFrame", "grpSp"]
                let choice = element.children(named: "Choice").first {
                    $0.elementChildren.contains { drawable.contains($0.local) }
                }
                if let pick = choice ?? element.child("Fallback") {
                    out += elements(of: pick, part: part, space: space)
                }
            default:
                break
            }
        }
        return out
    }

    /// A placeholder on a slide and what stands behind it: the matching one
    /// on the layout and on the master, farthest first, the shape itself
    /// last. Anything else is just itself.
    private func chain(_ element: XMLElement, part: PPTXPart) -> [PPTXSource] {
        let own = PPTXSource(element: element, part: part)
        guard part.isSlide, let placeholder = PPTXPlaceholder(of: element) else { return [own] }
        var sources: [PPTXSource] = []
        var behind = placeholder
        if let layout, let found = layout.counterpart(of: placeholder, byIndex: true) {
            sources.append(PPTXSource(element: found, part: layout))
            behind = PPTXPlaceholder(of: found) ?? placeholder
        }
        if let master, let found = master.part.counterpart(of: behind, byIndex: false) {
            sources.insert(PPTXSource(element: found, part: master.part), at: 0)
        }
        return sources + [own]
    }

    private static func xfrm(of element: XMLElement) -> XMLElement? {
        let xfrm: XMLElement?
        switch element.local {
        case "graphicFrame": xfrm = element.child("xfrm")
        case "grpSp": xfrm = element.child("grpSpPr")?.child("xfrm")
        default: xfrm = element.child("spPr")?.child("xfrm")
        }
        return xfrm?.child("ext") == nil ? nil : xfrm
    }

    /// The shape's own box in its own space; a placeholder that has none
    /// takes the box of the nearest one behind it, which is on the slide's.
    private func frame(of sources: [PPTXSource], space: PPTXSpace) -> PPTXFrame? {
        guard let own = sources.last else { return nil }
        if let xfrm = Self.xfrm(of: own.element) { return space.frame(xfrm) }
        for source in sources.dropLast().reversed() {
            if let xfrm = Self.xfrm(of: source.element) { return PPTXSpace.slide.frame(xfrm) }
        }
        return nil
    }

    // MARK: Shapes

    private mutating func shape(_ element: XMLElement, part: PPTXPart, space: PPTXSpace) -> String {
        let sources = chain(element, part: part)
        guard let frame = self.frame(of: sources, space: space) else { return "" }
        let geometry = sources.last {
            $0.element.child("spPr")?.child("prstGeom") != nil
                || $0.element.child("spPr")?.child("custGeom") != nil
        }?.element.child("spPr")
        let style = sources.last { $0.element.child("style") != nil }?.element.child("style")

        var fill: PPTXFill?
        for source in sources.reversed() {
            if let found = self.fill(in: source.element.child("spPr"), part: source.part) {
                fill = found
                break
            }
        }
        if fill == nil, let reference = style?.child("fillRef") { fill = styleFill(reference) }
        var line = style?.child("lnRef").map(styleLine) ?? PPTXLine()
        for source in sources {
            line.merge(self.line(source.element.child("spPr")?.child("ln"), part: source.part))
        }

        var out = "<div class=\"shape\" style=\"\(frame.css)\">"
        if let outline = Self.outline(of: geometry, width: frame.width, height: frame.height) {
            out += drawing(outline, width: frame.width, height: frame.height, fill: fill, line: line,
                           flipH: frame.flipH, flipV: frame.flipV)
        }
        if let txBody = element.child("txBody") {
            var body = PPTXBodyProps()
            for source in sources {
                body.merge(bodyProps(source.element.child("txBody")?.child("bodyPr")))
            }
            var list = baseStyle(for: PPTXPlaceholder(of: element))
            // The shape style's font: what text on a drawn shape is set in
            // when nothing nearer says — white on an accent fill, typically.
            if let fontRef = style?.child("fontRef") {
                var run = PPTXRunProps()
                run.color = color(in: fontRef)?.css
                switch fontRef.attr("idx") {
                case "major": run.font = theme.majorFont
                case "minor": run.font = theme.minorFont
                default: break
                }
                list.mergeRuns(run)
            }
            for source in sources {
                list.merge(listStyle(source.element.child("txBody")?.child("lstStyle")))
            }
            out += textBox(txBody, list: list, body: body)
        }
        return out + "</div>"
    }

    /// The text styles a shape's own begin from: the master's for its
    /// placeholder's family, the master's `otherStyle` for anything else.
    private func baseStyle(for placeholder: PPTXPlaceholder?) -> PPTXListStyle {
        guard let master else {
            var style = PPTXListStyle()
            style.mergeRuns(PPTXRunProps(size: 18, color: "#000000", font: theme.minorFont))
            style.merge(listStyle(defaultTextStyle))
            return style
        }
        switch placeholder?.kind {
        case "title": return master.titleStyle
        case "body": return master.bodyStyle
        default: return master.otherStyle
        }
    }

    private mutating func picture(_ element: XMLElement, part: PPTXPart, space: PPTXSpace) -> String {
        let sources = chain(element, part: part)
        guard let frame = self.frame(of: sources, space: space),
              let blipFill = element.child("blipFill"),
              let id = blipFill.child("blip")?.attr("embed"),
              let target = part.rels[id], !target.isExternal, Self.isDrawable(target.path)
        else { return "" }
        // `srcRect` takes a share off each side; the picture is drawn that
        // much larger and the box shows what is left.
        let crop = blipFill.child("srcRect")
        func share(_ name: String) -> Double { crop?.attr(name).flatMap(Self.fraction) ?? 0 }
        let (left, top, right, bottom) = (share("l"), share("t"), share("r"), share("b"))
        let shownWidth = max(1 - left - right, 0.01)
        let shownHeight = max(1 - top - bottom, 0.01)
        let place = "left:\(Self.number(-left / shownWidth * 100))%;"
            + "top:\(Self.number(-top / shownHeight * 100))%;"
            + "width:\(Self.number(100 / shownWidth))%;height:\(Self.number(100 / shownHeight))%"

        let geometry = sources.last { $0.element.child("spPr")?.child("prstGeom") != nil }?
            .element.child("spPr")
        var clip: [String] = []
        switch geometry?.child("prstGeom")?.attr("prst") {
        case "ellipse": clip.append("border-radius:50%")
        case "roundRect":
            let radius = min(frame.width, frame.height) * Self.adjust(geometry, "adj", 0.166_67)
            clip.append("border-radius:\(Self.number(radius))pt")
        default: break
        }
        var flips: [String] = []
        if frame.flipH { flips.append("scaleX(-1)") }
        if frame.flipV { flips.append("scaleY(-1)") }
        if !flips.isEmpty { clip.append("transform:\(flips.joined(separator: " "))") }

        var line = PPTXLine()
        for source in sources {
            line.merge(self.line(source.element.child("spPr")?.child("ln"), part: source.part))
        }
        var out = "<div class=\"shape\" style=\"\(frame.css)\">"
            + "<div class=\"crop\" style=\"\(clip.joined(separator: ";"))\">"
            + "<img src=\"\(Self.escape(target.path))\" style=\"\(place)\" alt=\"\"></div>"
        if line.fill?.color != nil,
           let outline = Self.outline(of: geometry, width: frame.width, height: frame.height) {
            out += drawing(outline, width: frame.width, height: frame.height, fill: nil, line: line)
        }
        return out + "</div>"
    }

    /// A table; a chart, a SmartArt diagram or an embedded object is left
    /// out.
    private mutating func graphicFrame(_ element: XMLElement, part: PPTXPart, space: PPTXSpace) -> String {
        guard let table = element.child("graphic")?.child("graphicData")?.child("tbl"),
              let frame = self.frame(of: chain(element, part: part), space: space) else { return "" }
        return "<div class=\"shape\" style=\"\(frame.css)\">"
            + self.table(table, part: part, space: space) + "</div>"
    }

    private mutating func group(_ element: XMLElement, part: PPTXPart, space: PPTXSpace) -> String {
        let properties = element.child("grpSpPr")
        let saved = groupFill
        defer { groupFill = saved }
        if let fill = fill(in: properties, part: part) { groupFill = fill }
        guard let xfrm = Self.xfrm(of: element) else {
            return elements(of: element, part: part, space: space)
        }
        // A group's flip would mirror its words too; only its turn is kept.
        let frame = space.frame(xfrm)
        let inner = elements(of: element, part: part, space: space.inside(xfrm))
        return "<div class=\"group\" style=\"\(frame.css)\">\(inner)</div>"
    }

    // MARK: Drawing

    /// One outline, in points from the box's top left, painted as SVG: the
    /// browser strokes it on its centre line, as PowerPoint does, and a fill
    /// prints as ink rather than as a background a printer may drop.
    private mutating func drawing(
        _ outline: String, width: Double, height: Double, fill: PPTXFill?, line: PPTXLine,
        flipH: Bool = false, flipV: Bool = false
    ) -> String {
        var definitions = ""
        var pictures = ""
        var paint = "none"
        switch fill {
        case .solid(let color):
            paint = color.css
        case .gradient(let stops, let angle, let radial):
            let id = nextDefinition()
            let tags = stops.map {
                "<stop offset=\"\(Self.number($0.position))\" stop-color=\"\($0.color.css)\"/>"
            }.joined()
            if radial {
                definitions += "<radialGradient id=\"\(id)\" cx=\".5\" cy=\".5\" r=\".71\">\(tags)"
                    + "</radialGradient>"
            } else {
                let radians = angle * .pi / 180
                let dx = cos(radians) / 2
                let dy = sin(radians) / 2
                definitions += "<linearGradient id=\"\(id)\" x1=\"\(Self.number(0.5 - dx))\" "
                    + "y1=\"\(Self.number(0.5 - dy))\" x2=\"\(Self.number(0.5 + dx))\" "
                    + "y2=\"\(Self.number(0.5 + dy))\">\(tags)</linearGradient>"
            }
            paint = "url(#\(id))"
        case .picture(let path):
            let id = nextDefinition()
            definitions += "<clipPath id=\"\(id)\"><path d=\"\(outline)\"/></clipPath>"
            pictures += "<image href=\"\(Self.escape(path))\" x=\"0\" y=\"0\" "
                + "width=\"\(Self.number(width))\" height=\"\(Self.number(height))\" "
                + "preserveAspectRatio=\"none\" clip-path=\"url(#\(id))\"/>"
        case .clear, nil:
            break
        }
        var stroke = ""
        if let color = line.fill?.color {
            let weight = line.width ?? 0.75
            stroke = " stroke=\"\(color.css)\" stroke-width=\"\(Self.number(weight))\""
            if let pattern = Self.dashes[line.dash ?? "solid"] {
                stroke += " stroke-dasharray=\""
                    + pattern.map { Self.number($0 * weight) }.joined(separator: " ") + "\""
            }
        }
        guard paint != "none" || !stroke.isEmpty || !pictures.isEmpty else { return "" }
        var shapes = pictures
        if paint != "none" || !stroke.isEmpty {
            shapes += "<path d=\"\(outline)\" fill=\"\(paint)\"\(stroke)/>"
        }
        if flipH || flipV {
            let transform = "translate(\(flipH ? Self.number(width) : "0") "
                + "\(flipV ? Self.number(height) : "0")) scale(\(flipH ? -1 : 1) \(flipV ? -1 : 1))"
            shapes = "<g transform=\"\(transform)\">\(shapes)</g>"
        }
        if !definitions.isEmpty { definitions = "<defs>\(definitions)</defs>" }
        // Drawn in points; an SVG's own unit is the CSS pixel.
        return "<svg class=\"geometry\"><g transform=\"scale(1.333333)\">"
            + "\(definitions)\(shapes)</g></svg>"
    }

    private mutating func nextDefinition() -> String {
        paints += 1
        return "nota-paint-\(paints)"
    }

    /// `prstDash` patterns, in line widths.
    private static let dashes: [String: [Double]] = [
        "dash": [4, 3], "dashDot": [4, 3, 1, 3], "dot": [1, 3], "lgDash": [8, 3],
        "lgDashDot": [8, 3, 1, 3], "lgDashDotDot": [8, 3, 1, 3, 1, 3], "sysDash": [3, 1],
        "sysDot": [1, 1], "sysDashDot": [3, 1, 1, 1], "sysDashDotDot": [3, 1, 1, 1, 1, 1],
    ]

    static func rectangle(_ width: Double, _ height: Double) -> String {
        "M0 0H\(number(width))V\(number(height))H0Z"
    }

    /// A preset's adjust value (`<a:gd name="adj" fmla="val 16667"/>`), as a
    /// share.
    private static func adjust(_ spPr: XMLElement?, _ name: String, _ fallback: Double) -> Double {
        let guide = spPr?.child("prstGeom")?.child("avLst")?.children(named: "gd")
            .first { $0.attr("name") == name }
        guard let formula = guide?.attr("fmla"), formula.hasPrefix("val "),
              let value = Double(formula.dropFirst(4)) else { return fallback }
        return value / 100_000
    }

    /// The outline a `spPr`'s geometry draws, in points; `nil` for a
    /// freeform written in terms this does not follow.
    private static func outline(of spPr: XMLElement?, width w: Double, height h: Double) -> String? {
        if let custom = spPr?.child("custGeom") { return freeform(custom, width: w, height: h) }
        let preset = spPr?.child("prstGeom")?.attr("prst") ?? "rect"
        let short = min(w, h)
        func polygon(_ points: [(Double, Double)]) -> String {
            "M" + points.map { "\(number($0.0)) \(number($0.1))" }.joined(separator: "L") + "Z"
        }
        switch preset {
        case "roundRect":
            let r = min(short * adjust(spPr, "adj", 0.166_67), short / 2)
            let (rr, ww, hh) = (number(r), number(w), number(h))
            return "M\(rr) 0H\(number(w - r))A\(rr) \(rr) 0 0 1 \(ww) \(rr)V\(number(h - r))"
                + "A\(rr) \(rr) 0 0 1 \(number(w - r)) \(hh)H\(rr)A\(rr) \(rr) 0 0 1 0 \(number(h - r))"
                + "V\(rr)A\(rr) \(rr) 0 0 1 \(rr) 0Z"
        case "ellipse", "flowChartConnector":
            let (rx, ry) = (number(w / 2), number(h / 2))
            return "M0 \(ry)A\(rx) \(ry) 0 1 1 \(number(w)) \(ry)A\(rx) \(ry) 0 1 1 0 \(ry)Z"
        case "triangle", "flowChartExtract":
            return polygon([(w * adjust(spPr, "adj", 0.5), 0), (w, h), (0, h)])
        case "rtTriangle":
            return polygon([(0, 0), (w, h), (0, h)])
        case "diamond", "flowChartDecision":
            return polygon([(w / 2, 0), (w, h / 2), (w / 2, h), (0, h / 2)])
        case "parallelogram":
            let x = short * adjust(spPr, "adj", 0.25)
            return polygon([(x, 0), (w, 0), (w - x, h), (0, h)])
        case "trapezoid":
            let x = short * adjust(spPr, "adj", 0.25)
            return polygon([(0, h), (x, 0), (w - x, 0), (w, h)])
        case "homePlate":
            let x = w - short * adjust(spPr, "adj", 0.5)
            return polygon([(0, 0), (x, 0), (w, h / 2), (x, h), (0, h)])
        case "chevron":
            let x = short * adjust(spPr, "adj", 0.5)
            return polygon([(0, 0), (w - x, 0), (w, h / 2), (w - x, h), (0, h), (x, h / 2)])
        case "line":
            return "M0 0L\(number(w)) \(number(h))"
        default:
            // A connector, whatever bends it was given, is drawn from end to
            // end; any other preset as the box it fills.
            if preset.hasSuffix("Connector1") || preset.contains("Connector") {
                return "M0 0L\(number(w)) \(number(h))"
            }
            return rectangle(w, h)
        }
    }

    /// A freeform's paths, each scaled from its own `w`×`h` into the box. A
    /// point written as a guide's name rather than a number gives the whole
    /// outline up.
    private static func freeform(_ custom: XMLElement, width w: Double, height h: Double) -> String? {
        var d = ""
        for path in custom.child("pathLst")?.children(named: "path") ?? [] {
            let pathWidth = path.attr("w").flatMap(Double.init) ?? 0
            let pathHeight = path.attr("h").flatMap(Double.init) ?? 0
            let sx = pathWidth > 0 ? w / pathWidth : 1 / 12_700
            let sy = pathHeight > 0 ? h / pathHeight : 1 / 12_700
            var current = (x: 0.0, y: 0.0)
            for command in path.elementChildren {
                var points: [(x: Double, y: Double)] = []
                for point in command.children(named: "pt") {
                    guard let x = point.attr("x").flatMap(Double.init),
                          let y = point.attr("y").flatMap(Double.init) else { return nil }
                    points.append((x * sx, y * sy))
                }
                func written(_ list: [(x: Double, y: Double)]) -> String {
                    list.map { "\(number($0.x)) \(number($0.y))" }.joined(separator: " ")
                }
                switch command.local {
                case "moveTo", "lnTo":
                    guard let point = points.first else { continue }
                    d += (command.local == "moveTo" ? "M" : "L") + written([point])
                    current = point
                case "cubicBezTo", "quadBezTo":
                    guard points.count == (command.local == "cubicBezTo" ? 3 : 2) else { continue }
                    d += (command.local == "cubicBezTo" ? "C" : "Q") + written(points)
                    current = points[points.count - 1]
                case "arcTo":
                    guard let wR = command.attr("wR").flatMap(Double.init),
                          let hR = command.attr("hR").flatMap(Double.init),
                          let start = command.attr("stAng").flatMap(Double.init),
                          let swing = command.attr("swAng").flatMap(Double.init) else { return nil }
                    let (rx, ry) = (wR * sx, hR * sy)
                    let from = start / 60_000 * .pi / 180
                    let sweep = swing / 60_000 * .pi / 180
                    let centre = (x: current.x - rx * cos(from), y: current.y - ry * sin(from))
                    // A full turn is drawn as two halves; SVG has no arc that
                    // ends where it starts.
                    let pieces = abs(sweep) > .pi * 1.99 ? 2 : 1
                    for piece in 1 ... pieces {
                        let angle = from + sweep * Double(piece) / Double(pieces)
                        let end = (x: centre.x + rx * cos(angle), y: centre.y + ry * sin(angle))
                        let large = abs(sweep / Double(pieces)) > .pi ? 1 : 0
                        d += "A\(number(rx)) \(number(ry)) 0 \(large) \(sweep > 0 ? 1 : 0) "
                            + written([end])
                        current = end
                    }
                case "close":
                    d += "Z"
                default:
                    break
                }
            }
        }
        return d.isEmpty ? nil : d
    }

    // MARK: Text

    private mutating func textBox(_ txBody: XMLElement, list: PPTXListStyle, body: PPTXBodyProps) -> String {
        var css = ["padding:\(Self.number(body.top ?? 3.6))pt \(Self.number(body.right ?? 7.2))pt "
            + "\(Self.number(body.bottom ?? 3.6))pt \(Self.number(body.left ?? 7.2))pt"]
        switch body.anchor {
        case "ctr": css.append("justify-content:center")
        case "b": css.append("justify-content:flex-end")
        default: break
        }
        switch body.vertical {
        case "vert", "eaVert", "mongolianVert", "wordArtVertRtl":
            css.append("writing-mode:vertical-rl")
        case "vert270":
            css.append("writing-mode:vertical-rl;transform:rotate(180deg)")
        default:
            break
        }
        var counters: [Int: Int] = [:]
        var out = ""
        for (index, paragraph) in txBody.children(named: "p").enumerated() {
            out += self.paragraph(paragraph, list: list, body: body, isFirst: index == 0,
                                  counters: &counters)
        }
        return "<div class=\"text\" style=\"\(css.joined(separator: ";"))\">\(out)</div>"
    }

    private mutating func paragraph(
        _ element: XMLElement, list: PPTXListStyle, body: PPTXBodyProps, isFirst: Bool,
        counters: inout [Int: Int]
    ) -> String {
        let pPr = element.child("pPr")
        let level = min(8, max(0, pPr?.attr("lvl").flatMap(Int.init) ?? 0))
        var props = list.levels[level]
        props.merge(paraProps(pPr))
        let scale = body.fontScale ?? 1

        var inner = ""
        var words = ""
        var lead: PPTXRunProps?
        for child in element.elementChildren {
            switch child.local {
            case "r", "fld":
                let run = props.run.merged(runProps(child.child("rPr")))
                var text = child.child("t")?.stringValue ?? ""
                if child.local == "fld", child.attr("type") == "slidenum" { text = String(slideNumber) }
                guard !text.isEmpty else { continue }
                if lead == nil { lead = run }
                words += text
                let css = run.css(scale: scale)
                inner += css.isEmpty ? Self.escape(text) : "<span style=\"\(css)\">\(Self.escape(text))</span>"
            case "br":
                words += "\n"
                inner += "<br>"
            default:
                break
            }
        }
        let end = props.run.merged(runProps(element.child("endParaRPr")))
        let text = lead ?? end
        let size = (text.size ?? 18) * scale
        if !words.isEmpty { lines.append(words) }

        // Numbers count on through a level, start again under a shallower
        // one, and a paragraph with no number at a level ends that count.
        for deeper in counters.keys where deeper > level { counters[deeper] = nil }
        var marker = ""
        var markerFont = props.bulletFont
        if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch props.bullet {
            case .number(let scheme, let start):
                let value = (counters[level] ?? start - 1) + 1
                counters[level] = value
                marker = Self.autoNumber(value, scheme: scheme)
                markerFont = ""
            case .character(let character):
                counters[level] = nil
                let glyph = Self.bulletGlyph(character, font: props.bulletFont)
                marker = glyph.text
                if !glyph.keepsFont { markerFont = "" }
            case .off, nil:
                counters[level] = nil
            }
        }

        var css = ["font-size:\(Self.number(size))pt"]
        if let align = props.align { css.append("text-align:\(align)") }
        let left = props.marginLeft ?? 0
        let indent = props.indent ?? 0
        if left != 0 { css.append("padding-left:\(Self.number(left))pt") }
        if indent != 0 { css.append("text-indent:\(Self.number(indent))pt") }
        let reduction = body.lineReduction ?? 0
        switch props.line {
        case .percent(let share): css.append("line-height:\(Self.number(max(share - reduction, 0.1) * 1.2))")
        case .points(let points): css.append("line-height:\(Self.number(points))pt")
        case nil: css.append("line-height:\(Self.number(max(1 - reduction, 0.1) * 1.2))")
        }
        // PowerPoint keeps no space above a text box's first paragraph.
        if !isFirst, let before = props.before?.inPoints(size: size), before > 0 {
            css.append("padding-top:\(Self.number(before))pt")
        }
        if let after = props.after?.inPoints(size: size), after > 0 {
            css.append("padding-bottom:\(Self.number(after))pt")
        }
        if body.wrap == false { css.append("white-space:pre") }
        if lead == nil, let color = end.color { css.append("color:\(color)") }

        var html = "<p style=\"\(css.joined(separator: ";"))\">"
        if !marker.isEmpty {
            var style: [String] = []
            if indent < 0 {
                style.append("min-width:\(Self.number(-indent))pt")
            } else {
                style.append("padding-right:.3em")
            }
            if let color = props.bulletColor, !color.isEmpty {
                style.append("color:\(color)")
            } else if let color = text.color {
                style.append("color:\(color)")
            }
            if let font = markerFont, !font.isEmpty {
                style.append("font-family:\(Self.fontStack(font))")
            } else if let font = text.font {
                style.append("font-family:\(Self.fontStack(font))")
            }
            if case .number = props.bullet {
                if let bold = text.bold { style.append("font-weight:\(bold ? "bold" : "normal")") }
                if let italic = text.italic { style.append("font-style:\(italic ? "italic" : "normal")") }
            }
            let markerSize: Double
            switch props.bulletSize {
            case .percent(let share): markerSize = share * size
            case .points(let points): markerSize = points * scale
            case nil: markerSize = size
            }
            style.append("font-size:\(Self.number(markerSize))pt")
            html += "<span class=\"bullet\" style=\"\(style.joined(separator: ";"))\">"
                + "\(Self.escape(marker))</span>"
        }
        html += inner.isEmpty ? "<br>" : inner
        return html + "</p>"
    }

    /// A `buAutoNum` scheme's marker: the counter (`arabic`, `alphaLc`,
    /// `romanUc`, …) and what is written round it (`Period`, `ParenR`,
    /// `ParenBoth`, `Plain`).
    static func autoNumber(_ value: Int, scheme: String) -> String {
        let counter: String
        if scheme.hasPrefix("alphaLc") {
            counter = letters(value).lowercased()
        } else if scheme.hasPrefix("alphaUc") {
            counter = letters(value)
        } else if scheme.hasPrefix("romanLc") {
            counter = roman(value).lowercased()
        } else if scheme.hasPrefix("romanUc") {
            counter = roman(value)
        } else {
            counter = "\(value)"
        }
        if scheme.hasSuffix("ParenBoth") { return "(\(counter))" }
        if scheme.hasSuffix("ParenR") { return "\(counter))" }
        if scheme.hasSuffix("Period") { return "\(counter)." }
        if scheme.hasSuffix("Minus") { return "- \(counter) -" }
        return counter
    }

    private static func letters(_ value: Int) -> String {
        guard value > 0 else { return "\(value)" }
        // a, b, …, z, aa, bb, … — the letter repeated.
        let letter = Character(UnicodeScalar(65 + (value - 1) % 26)!)
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else { return "\(value)" }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var rest = value
        var out = ""
        for (amount, glyph) in table {
            while rest >= amount {
                out += glyph
                rest -= amount
            }
        }
        return out
    }

    /// A bullet as PowerPoint writes it is often a letter in Wingdings or
    /// Symbol, which draws something else entirely; this is the character
    /// it draws, set in the text's own font (`keepsFont` false) so the Mac
    /// does not draw the letter.
    static func bulletGlyph(_ character: String, font: String?) -> (text: String, keepsFont: Bool) {
        let face = font?.lowercased() ?? ""
        var key = character
        if let scalar = character.unicodeScalars.first, (0xF000 ... 0xF0FF).contains(scalar.value),
           let low = UnicodeScalar(scalar.value - 0xF000) {
            key = String(Character(low))
        } else if !face.contains("wingdings"), !face.contains("symbol") {
            return (character, true)
        }
        if face.contains("symbol") {
            return (["·": "•", "o": "◦", "®": "→", "Þ": "⇒"][key] ?? "•", false)
        }
        let wingdings: [String: String] = [
            "§": "▪", "Ø": "➢", "ü": "✓", "v": "❖", "q": "❑", "n": "■", "l": "●", "o": "□",
            "à": "➔", "è": "➔", "Ÿ": "•", "w": "⬥", "u": "◆", "¨": "◻", "þ": "☑", "ð": "➢",
        ]
        return (wingdings[key] ?? "•", false)
    }

    // MARK: Tables

    /// One part of a table style (`wholeTbl`, `firstRow`, `band1H`, …): what
    /// it fills its cells with, sets their text in, and rules them with.
    private struct CellStyle {
        var fill: PPTXFill?
        var run = PPTXRunProps()
        /// `left`, `right`, `top`, `bottom`, `insideH`, `insideV`.
        var borders: [String: PPTXLine] = [:]
    }

    private func cellStyle(_ element: XMLElement?) -> CellStyle? {
        guard let element else { return nil }
        var style = CellStyle()
        if let text = element.child("tcTxStyle") {
            if let bold = text.attr("b") { style.run.bold = bold == "on" }
            if let italic = text.attr("i") { style.run.italic = italic == "on" }
            if let fontRef = text.child("fontRef") {
                style.run.font = fontRef.attr("idx") == "major" ? theme.majorFont : theme.minorFont
                style.run.color = color(in: fontRef)?.css
            }
            if let face = typeface(text.child("font")?.child("latin")?.attr("typeface")) {
                style.run.font = face
            }
            if let color = color(in: text) { style.run.color = color.css }
        }
        if let cell = element.child("tcStyle") {
            if let holder = cell.child("fill") {
                style.fill = fill(in: holder, part: nil)
            } else if let reference = cell.child("fillRef") {
                style.fill = styleFill(reference)
            }
            for edge in cell.child("tcBdr")?.elementChildren ?? [] {
                if let ln = edge.child("ln") {
                    style.borders[edge.local] = line(ln, part: nil)
                } else if let reference = edge.child("lnRef") {
                    style.borders[edge.local] = styleLine(reference)
                }
            }
        }
        return style
    }

    private mutating func table(_ element: XMLElement, part: PPTXPart, space: PPTXSpace) -> String {
        let tblPr = element.child("tblPr")
        func says(_ name: String) -> Bool { Self.isOn(tblPr?.attr(name)) }
        var styleElement = tblPr?.child("tableStyle")
        if styleElement == nil,
           let id = tblPr?.child("tableStyleId")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            styleElement = tableStyles[id]
        }
        var parts: [String: CellStyle] = [:]
        for name in ["wholeTbl", "band1H", "band2H", "band1V", "band2V", "firstCol", "lastCol",
                     "firstRow", "lastRow"] {
            parts[name] = cellStyle(styleElement?.child(name))
        }

        let widths = (element.child("tblGrid")?.children(named: "gridCol") ?? []).map {
            ($0.attr("w").flatMap(Double.init) ?? 0) * space.scaleX
        }
        let rows = element.children(named: "tr")
        let lastRow = rows.count - 1
        let lastColumn = widths.count - 1

        var css = ["width:\(Self.number(widths.reduce(0, +)))pt"]
        if let ground = fill(in: tblPr, part: part)?.color { css.append("background:\(ground.css)") }
        var out = "<table style=\"\(css.joined(separator: ";"))\"><colgroup>"
            + widths.map { "<col style=\"width:\(Self.number($0))pt\">" }.joined() + "</colgroup>"
        for (rowIndex, row) in rows.enumerated() {
            let height = (row.attr("h").flatMap(Double.init) ?? 0) * space.scaleY
            out += "<tr style=\"height:\(Self.number(height))pt\">"
            for (column, cell) in row.children(named: "tc").enumerated() {
                // A cell a merge covers is written, and left out.
                if Self.isOn(cell.attr("hMerge")) || Self.isOn(cell.attr("vMerge")) { continue }
                let columns = max(1, cell.attr("gridSpan").flatMap(Int.init) ?? 1)
                let rowsDown = max(1, cell.attr("rowSpan").flatMap(Int.init) ?? 1)
                let bounds = (top: rowIndex == 0, bottom: rowIndex + rowsDown - 1 >= lastRow,
                              left: column == 0, right: column + columns - 1 >= lastColumn)

                // The style's parts, broadest first: the whole table, the
                // banding, then the first and last columns and rows.
                var style = CellStyle()
                func apply(_ name: String, rowRegion: Bool = false, columnRegion: Bool = false) {
                    guard let part = parts[name] else { return }
                    if let fill = part.fill { style.fill = fill }
                    style.run.merge(part.run)
                    let edges = [
                        ("left", columnRegion || bounds.left ? "left" : "insideV"),
                        ("right", columnRegion || bounds.right ? "right" : "insideV"),
                        ("top", rowRegion || bounds.top ? "top" : "insideH"),
                        ("bottom", rowRegion || bounds.bottom ? "bottom" : "insideH"),
                    ]
                    for (side, source) in edges {
                        if let line = part.borders[source] { style.borders[side] = line }
                    }
                }
                apply("wholeTbl")
                let isHeader = says("firstRow") && rowIndex == 0
                let isFooter = says("lastRow") && rowIndex == lastRow
                if says("bandRow"), !isHeader, !isFooter {
                    let band = rowIndex - (says("firstRow") ? 1 : 0)
                    apply(band % 2 == 0 ? "band1H" : "band2H", rowRegion: true)
                }
                let isFirstColumn = says("firstCol") && column == 0
                let isLastColumn = says("lastCol") && bounds.right
                if says("bandCol"), !isFirstColumn, !isLastColumn {
                    let band = column - (says("firstCol") ? 1 : 0)
                    apply(band % 2 == 0 ? "band1V" : "band2V", columnRegion: true)
                }
                if isFirstColumn { apply("firstCol", columnRegion: true) }
                if isLastColumn { apply("lastCol", columnRegion: true) }
                if isFooter { apply("lastRow", rowRegion: true) }
                if isHeader { apply("firstRow", rowRegion: true) }

                // Then what the cell says itself.
                let tcPr = cell.child("tcPr")
                if let fill = fill(in: tcPr, part: part) { style.fill = fill }
                for (side, name) in [("left", "lnL"), ("right", "lnR"), ("top", "lnT"), ("bottom", "lnB")] {
                    if let ln = tcPr?.child(name) {
                        var line = style.borders[side] ?? PPTXLine()
                        line.merge(self.line(ln, part: part))
                        style.borders[side] = line
                    }
                }
                func inset(_ name: String, _ fallback: Double) -> String {
                    Self.number(tcPr?.attr(name).flatMap(Double.init).map { $0 / 12_700 } ?? fallback)
                }
                var cellCSS = ["padding:\(inset("marT", 3.6))pt \(inset("marR", 7.2))pt "
                    + "\(inset("marB", 3.6))pt \(inset("marL", 7.2))pt"]
                switch tcPr?.attr("anchor") {
                case "ctr": cellCSS.append("vertical-align:middle")
                case "b": cellCSS.append("vertical-align:bottom")
                default: cellCSS.append("vertical-align:top")
                }
                if let ground = style.fill?.color { cellCSS.append("background:\(ground.css)") }
                for side in ["left", "right", "top", "bottom"] {
                    if let line = style.borders[side] { cellCSS.append("border-\(side):\(line.cssBorder)") }
                }

                var list = baseStyle(for: nil)
                list.mergeRuns(style.run)
                var paragraphs = ""
                if let txBody = cell.child("txBody") {
                    list.merge(listStyle(txBody.child("lstStyle")))
                    var counters: [Int: Int] = [:]
                    for (index, paragraph) in txBody.children(named: "p").enumerated() {
                        paragraphs += self.paragraph(paragraph, list: list, body: PPTXBodyProps(),
                                                     isFirst: index == 0, counters: &counters)
                    }
                }
                out += "<td"
                if columns > 1 { out += " colspan=\"\(columns)\"" }
                if rowsDown > 1 { out += " rowspan=\"\(rowsDown)\"" }
                out += " style=\"\(cellCSS.joined(separator: ";"))\">\(paragraphs)</td>"
            }
            out += "</tr>"
        }
        return out + "</table>"
    }

    /// PowerPoint's default table style, "Medium Style 2 – Accent 1", which a
    /// deck names by id and may not write out: its definition, as
    /// `tableStyles.xml` would hold it.
    static let mediumStyle2ID = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"
    static let mediumStyle2: String = {
        let rule = { (side: String, width: Int) in
            "<a:\(side)><a:ln w=\"\(width)\"><a:solidFill><a:schemeClr val=\"lt1\"/></a:solidFill>"
                + "</a:ln></a:\(side)>"
        }
        let accent = { (tint: String) in
            "<a:fill><a:solidFill><a:schemeClr val=\"accent1\">\(tint)</a:schemeClr></a:solidFill></a:fill>"
        }
        let strong = "<a:tcTxStyle b=\"on\"><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef>"
            + "<a:schemeClr val=\"lt1\"/></a:tcTxStyle>"
        let all = ["left", "right", "top", "bottom", "insideH", "insideV"].map { rule($0, 12_700) }.joined()
        return "<a:tblStyle xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            + "styleId=\"\(PPTXConverter.mediumStyle2ID)\" styleName=\"Medium Style 2 - Accent 1\">"
            + "<a:wholeTbl><a:tcTxStyle><a:fontRef idx=\"minor\"><a:prstClr val=\"black\"/></a:fontRef>"
            + "<a:schemeClr val=\"dk1\"/></a:tcTxStyle><a:tcStyle><a:tcBdr>\(all)</a:tcBdr>"
            + accent("<a:tint val=\"20000\"/>") + "</a:tcStyle></a:wholeTbl>"
            + "<a:band1H><a:tcStyle><a:tcBdr/>" + accent("<a:tint val=\"40000\"/>") + "</a:tcStyle></a:band1H>"
            + "<a:band1V><a:tcStyle><a:tcBdr/>" + accent("<a:tint val=\"40000\"/>") + "</a:tcStyle></a:band1V>"
            + "<a:lastCol>\(strong)<a:tcStyle><a:tcBdr/>" + accent("") + "</a:tcStyle></a:lastCol>"
            + "<a:firstCol>\(strong)<a:tcStyle><a:tcBdr/>" + accent("") + "</a:tcStyle></a:firstCol>"
            + "<a:lastRow>\(strong)<a:tcStyle><a:tcBdr>\(rule("top", 38_100))</a:tcBdr>" + accent("")
            + "</a:tcStyle></a:lastRow>"
            + "<a:firstRow>\(strong)<a:tcStyle><a:tcBdr>\(rule("bottom", 38_100))</a:tcBdr>" + accent("")
            + "</a:tcStyle></a:firstRow></a:tblStyle>"
    }()

    // MARK: The page

    private func page(_ slides: String) -> String {
        let width = Self.number(Double(slideSize.width))
        let height = Self.number(Double(slideSize.height))
        let titleTag = title.map { "<title>\(Self.escape($0))</title>" } ?? ""
        // Each slide is a sheet: exactly the paper's width, so the print is
        // not scaled, and a pixel short of its height, so a rounding in the
        // printer's page height can never push a sliver of a slide — and,
        // after its forced break, the next whole slide — onto a page of its
        // own. The colours are printed as they are, not saved as ink.
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width">\(titleTag)
        <style>
        @page { size: \(width)pt \(height)pt; margin: 0; }
        html, body { margin: 0; padding: 0; background: #fff; }
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        .slide {
          position: relative; width: \(width)pt; height: calc(\(height)pt - 1px); overflow: hidden;
          background: #fff; color: #000; color-scheme: light;
          font-family: \(Self.fontStack(theme.minorFont)); font-size: 18pt; line-height: 1.2;
          break-after: page; page-break-after: always; break-inside: avoid; page-break-inside: avoid;
        }
        .slide:last-child { break-after: auto; page-break-after: auto; }
        .shape, .group { position: absolute; box-sizing: border-box; }
        .geometry { position: absolute; left: 0; top: 0; width: 100%; height: 100%; overflow: visible; }
        .text {
          position: absolute; left: 0; top: 0; right: 0; bottom: 0; box-sizing: border-box;
          display: flex; flex-direction: column; overflow-wrap: break-word; tab-size: 72pt;
        }
        .text p, td p { margin: 0; white-space: pre-wrap; }
        .bullet { display: inline-block; text-indent: 0; box-sizing: border-box; }
        .crop { position: absolute; left: 0; top: 0; right: 0; bottom: 0; overflow: hidden; }
        .crop img { position: absolute; display: block; max-width: none; }
        table { border-collapse: collapse; table-layout: fixed; }
        td { box-sizing: border-box; overflow-wrap: break-word; }
        @media screen {
          html, body { background: #e8e8e8; }
          body { padding: 16px; }
          .slide { margin: 0 auto 16px; box-shadow: 0 1px 4px rgba(0,0,0,.18); }
        }
        </style></head>
        <body>\(slides)</body></html>
        """
    }

    // MARK: Helpers

    /// `1`, `true` and `on` — DrawingML's booleans, written all three ways.
    static func isOn(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "on"].contains(value.lowercased())
    }

    /// A DrawingML share as a fraction: `100000` and `100%` are both 1.
    static func fraction(_ value: String) -> Double? {
        if value.hasSuffix("%") { return Double(value.dropLast()).map { $0 / 100 } }
        return Double(value).map { $0 / 100_000 }
    }

    /// A metafile is a Windows drawing WebKit cannot draw: a picture that
    /// would be a broken-image box is better left out.
    static func isDrawable(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ![".emf", ".wmf", ".emz", ".wmz"].contains { lower.hasSuffix($0) }
    }

    static func fontStack(_ name: String) -> String {
        let lower = name.lowercased()
        let generic: String
        if ["courier", "consolas", "mono", "menlo", "lucida console"].contains(where: lower.contains) {
            generic = "Menlo, monospace"
        } else if !lower.contains("sans"),
                  ["times", "cambria", "georgia", "garamond", "book", "baskerville", "palatino",
                   "serif", "minion", "constantia", "song", "ming", "宋", "明"]
                  .contains(where: lower.contains) {
            generic = "'Times New Roman', Georgia, serif"
        } else {
            generic = "'Helvetica Neue', Helvetica, Arial, sans-serif"
        }
        let quoted = name.replacingOccurrences(of: "'", with: "")
        return "'\(quoted)', \(generic)"
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}
