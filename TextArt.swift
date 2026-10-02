import AppKit

struct TextArt {

    struct Run {
        var text: String
        var foreground: NSColor? = nil
        var background: NSColor? = nil
    }

    private static let vgaPalette: [UInt32] = [
        0x000000, 0xAA0000, 0x00AA00, 0xAA5500, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
        0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF
    ]

    private static let attributePalette: [UInt32] = (0..<16).map { index in
        vgaPalette[index & 0b1010 | (index & 1) << 2 | (index & 4) >> 2]
    }

    private static let characters: [Character] = (0...255).map { byte in
        guard byte >= 0x20, byte != 0x7F,
              let decoded = String(bytes: [UInt8(byte)], encoding: SharedCode.nfoEncoding()) else { return " " }
        return Character(decoded)
    }

    var lines: [[Run]]
    var columns: Int
    var background: NSColor?
    var bitmap: Bitmap? = nil

    static func load(from url: URL, maximumLines: Int = 100_000) throws -> TextArt {
        let bytes = [UInt8](try Data(contentsOf: url))
        if let bitmap = Bitmap(xbin: bytes, maximumRows: maximumLines) {
            return TextArt(lines: [], columns: bitmap.columns, background: color(bitmap.palette[0]), bitmap: bitmap)
        }

        let sauce = Sauce(bytes)
        var content = bytes[..<(sauce?.contentLength ?? bytes.count)]
        if let end = content.firstIndex(of: 0x1A) {
            content = content[..<end]
        }

        let hasEscapeSequences = zip(content, content.dropFirst()).contains { $0 == 0x1B && $1 == 0x5B }
        if url.pathExtension.lowercased() == "ans" || sauce?.isANSI == true || hasEscapeSequences {
            var screen = ANSIScreen(columns: sauce?.columns ?? 80, maximumLines: maximumLines, iceColors: sauce?.iceColors ?? false)
            screen.interpret(content)
            return screen.art
        }

        guard let text = String(bytes: content, encoding: SharedCode.nfoEncoding()) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let parsed = SharedCode.nfoTrimming(text: text, maximumLines: maximumLines)
        return TextArt(lines: parsed.lines.map { [Run(text: $0)] }, columns: parsed.maxLineLength, background: nil)
    }

    func attributedString(font: NSFont) -> NSAttributedString {
        let kern = SharedCode.nfoCellWidth - ("M" as NSString).size(withAttributes: [.font: font]).width
        let result = NSMutableAttributedString()
        result.beginEditing()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            for run in line {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: kern, .foregroundColor: run.foreground ?? NSColor.textColor]
                if let background = run.background {
                    attributes[.backgroundColor] = background
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        result.endEditing()
        return result
    }

    func contentSize(lineHeight: CGFloat) -> NSSize {
        if let bitmap {
            return NSSize(width: bitmap.pixelWidth, height: bitmap.pixelHeight)
        }
        return NSSize(width: CGFloat(columns) * SharedCode.nfoCellWidth, height: CGFloat(lines.count) * lineHeight)
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    struct Bitmap {
        let columns: Int
        let rows: Int
        let glyphHeight: Int
        let palette: [UInt32]
        private let glyphs: [UInt8]
        private let cells: [UInt16]
        private let iceColors: Bool
        private let highGlyphs: Bool

        var pixelWidth: Int { columns * 8 }
        var pixelHeight: Int { rows * glyphHeight }

        init?(xbin bytes: [UInt8], maximumRows: Int) {
            guard bytes.count >= 11, bytes[0..<5].elementsEqual("XBIN\u{1A}".utf8) else { return nil }
            let width = Int(bytes[5]) | Int(bytes[6]) << 8
            let height = Int(bytes[7]) | Int(bytes[8]) << 8
            let flags = bytes[10]
            guard (1...4096).contains(width), height > 0, bytes[9] <= 32 else { return nil }

            var offset = 11
            func next() -> UInt8? {
                guard offset < bytes.count else { return nil }
                defer { offset += 1 }
                return bytes[offset]
            }
            func take(_ count: Int) -> [UInt8]? {
                guard offset + count <= bytes.count else { return nil }
                defer { offset += count }
                return Array(bytes[offset..<offset + count])
            }

            var palette = TextArt.attributePalette
            if flags & 0x01 != 0 {
                guard let values = take(48) else { return nil }
                palette = (0..<16).map { index in
                    values[index * 3..<index * 3 + 3].reduce(UInt32(0)) { rgb, value in
                        rgb << 8 | UInt32(value & 0x3F) << 2 | UInt32(value & 0x3F) >> 4
                    }
                }
            }

            highGlyphs = flags & 0x12 == 0x12
            if flags & 0x02 != 0 {
                glyphHeight = bytes[9] == 0 ? 16 : Int(bytes[9])
                guard let font = take(glyphHeight * (highGlyphs ? 512 : 256)) else { return nil }
                glyphs = font
            } else {
                glyphHeight = 16
                glyphs = TextArt.vgaGlyphs
            }

            var cells = [UInt16](repeating: 0, count: width * min(height, maximumRows))
            var index = 0
            if flags & 0x04 != 0 {
                decoding: while index < cells.count, let header = next() {
                    var character: UInt8?
                    var attribute: UInt8?
                    for _ in 0...(header & 0x3F) {
                        switch header & 0xC0 {
                        case 0x40:
                            if character == nil { character = next() }
                            attribute = next()
                        case 0x80:
                            if attribute == nil { attribute = next() }
                            character = next()
                        case 0xC0:
                            if character == nil { character = next() }
                            if attribute == nil { attribute = next() }
                        default:
                            character = next()
                            attribute = next()
                        }
                        guard let character, let attribute, index < cells.count else { break decoding }
                        cells[index] = UInt16(character) | UInt16(attribute) << 8
                        index += 1
                    }
                }
            } else {
                while index < cells.count, let character = next(), let attribute = next() {
                    cells[index] = UInt16(character) | UInt16(attribute) << 8
                    index += 1
                }
            }

            columns = width
            rows = cells.count / width
            self.palette = palette
            self.cells = cells
            iceColors = flags & 0x08 != 0
        }

        func image(columns: Range<Int>, rows: Range<Int>) -> CGImage? {
            let width = columns.count * 8
            var pixels = [UInt32](repeating: 0, count: width * rows.count * glyphHeight)
            for row in rows {
                for column in columns {
                    for line in 0..<glyphHeight {
                        let (bits, foreground, background) = cellLine(row: row, column: column, line: line)
                        let start = ((row - rows.lowerBound) * glyphHeight + line) * width + (column - columns.lowerBound) * 8
                        for bit in 0..<8 {
                            pixels[start + bit] = bits & (0x80 >> bit) != 0 ? foreground : background
                        }
                    }
                }
            }
            return Self.makeImage(pixels, width: width, height: rows.count * glyphHeight)
        }

        func scaledImage(width: Int, maximumHeight: Int) -> CGImage? {
            let scale = Double(width) / Double(pixelWidth)
            let height = min(maximumHeight, Int((Double(pixelHeight) * scale).rounded(.up)))
            let samples = min(max(Int((1 / scale).rounded(.up)), 1), 4)
            guard width > 0, height > 0 else { return nil }

            var pixels = [UInt32](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var red = 0
                    var green = 0
                    var blue = 0
                    for sampleY in 0..<samples {
                        let sourceY = min(Int((Double(y) + (Double(sampleY) + 0.5) / Double(samples)) / scale), pixelHeight - 1)
                        for sampleX in 0..<samples {
                            let sourceX = min(Int((Double(x) + (Double(sampleX) + 0.5) / Double(samples)) / scale), pixelWidth - 1)
                            let (bits, foreground, background) = cellLine(row: sourceY / glyphHeight, column: sourceX / 8, line: sourceY % glyphHeight)
                            let rgb = bits & (0x80 >> (sourceX % 8)) != 0 ? foreground : background
                            red += Int(rgb >> 16 & 0xFF)
                            green += Int(rgb >> 8 & 0xFF)
                            blue += Int(rgb & 0xFF)
                        }
                    }
                    let count = samples * samples
                    pixels[y * width + x] = UInt32(red / count) << 16 | UInt32(green / count) << 8 | UInt32(blue / count)
                }
            }
            return Self.makeImage(pixels, width: width, height: height)
        }

        private func cellLine(row: Int, column: Int, line: Int) -> (bits: UInt8, foreground: UInt32, background: UInt32) {
            let cell = cells[row * columns + column]
            let attribute = Int(cell >> 8)
            let glyph = Int(cell & 0xFF) | (highGlyphs && attribute & 0x08 != 0 ? 0x100 : 0)
            return (glyphs[glyph * glyphHeight + line], palette[attribute & 0x0F], palette[iceColors ? attribute >> 4 : attribute >> 4 & 0x07])
        }

        private static func makeImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
            guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    private static let vgaGlyphs: [UInt8] = {
        var glyphs = [UInt8](repeating: 0, count: 256 * 16)
        let font = CTFontCreateWithName(SharedCode.nfoFontName as CFString, 16, nil)
        guard let context = CGContext(data: nil, width: 8, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return glyphs }
        context.setShouldAntialias(false)
        let buffer = data.assumingMemoryBound(to: UInt8.self)

        for byte in 0..<256 {
            var units = Array(String(characters[byte]).utf16)
            var glyph = CGGlyph(0)
            guard units.count == 1, CTFontGetGlyphsForCharacters(font, &units, &glyph, 1) else { continue }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
            context.setFillColor(gray: 1, alpha: 1)
            var position = CGPoint(x: 0, y: CTFontGetDescent(font))
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            for line in 0..<16 {
                glyphs[byte * 16 + line] = (0..<8).reduce(UInt8(0)) { bits, x in
                    buffer[line * context.bytesPerRow + x] > 127 ? bits | 0x80 >> x : bits
                }
            }
        }
        return glyphs
    }()

    private struct Sauce {
        var contentLength: Int
        var isANSI: Bool
        var columns: Int?
        var iceColors: Bool

        init?(_ bytes: [UInt8]) {
            let record = bytes.count - 128
            guard record >= 0, bytes[record..<record + 5].elementsEqual("SAUCE".utf8) else { return nil }

            let dataType = bytes[record + 94]
            let fileType = bytes[record + 95]
            let width = Int(bytes[record + 96]) | Int(bytes[record + 97]) << 8
            let commentLines = Int(bytes[record + 104])
            let comments = record - 5 - commentLines * 64

            contentLength = commentLines > 0 && comments >= 0 && bytes[comments..<comments + 5].elementsEqual("COMNT".utf8) ? comments : record
            isANSI = dataType == 1 && fileType == 1
            columns = dataType == 1 && width > 0 ? min(width, 4096) : nil
            iceColors = dataType == 1 && bytes[record + 105] & 1 == 1
        }
    }

    private struct ANSIScreen {

        struct Cell {
            var byte: UInt8
            var foreground: UInt32
            var background: UInt32
        }

        static let blank = Cell(byte: 0x20, foreground: TextArt.vgaPalette[7], background: TextArt.vgaPalette[0])

        let columns: Int
        let maximumLines: Int
        var iceColors: Bool
        var rows: [[Cell]] = []
        var row = 0
        var column = 0
        var savedRow = 0
        var savedColumn = 0
        var foreground = 7
        var background = 0
        var foreground24: UInt32? = nil
        var background24: UInt32? = nil
        var bold = false
        var blink = false
        var inverse = false

        mutating func interpret(_ bytes: ArraySlice<UInt8>) {
            var index = bytes.startIndex
            while index < bytes.endIndex {
                if column >= columns {
                    row += 1
                    column = 0
                }
                switch bytes[index] {
                case 0x0A:
                    row += 1
                    column = 0
                case 0x0D:
                    break
                case 0x09:
                    column += 8
                case 0x1B:
                    if index + 1 < bytes.endIndex, bytes[index + 1] == 0x5B {
                        index = performSequence(bytes, start: index + 2)
                    }
                default:
                    put(bytes[index])
                }
                index += 1
            }
        }

        private mutating func performSequence(_ bytes: ArraySlice<UInt8>, start: Int) -> Int {
            var end = start
            while end < bytes.endIndex, end - start < 64, (0x20...0x3F).contains(bytes[end]) {
                end += 1
            }
            guard end < bytes.endIndex, (0x40...0x7E).contains(bytes[end]) else {
                return start - 1
            }

            let text = String(decoding: bytes[start..<end], as: UTF8.self)
            let isPrivate = text.hasPrefix("?")
            let parameters = text.drop { $0 == "?" }
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { min(Int($0) ?? 0, 0xFFFF) }
            let count = max(parameters[0], 1)

            switch bytes[end] {
            case UInt8(ascii: "A"):
                row = max(row - count, 0)
            case UInt8(ascii: "B"):
                row += count
            case UInt8(ascii: "C"):
                column = min(column + count, columns)
            case UInt8(ascii: "D"):
                column = max(column - count, 0)
            case UInt8(ascii: "H"), UInt8(ascii: "f"):
                row = max(parameters[0] - 1, 0)
                column = min(max((parameters.count > 1 ? parameters[1] : 1) - 1, 0), columns - 1)
            case UInt8(ascii: "s"):
                savedRow = row
                savedColumn = column
            case UInt8(ascii: "u"):
                row = savedRow
                column = savedColumn
            case UInt8(ascii: "J") where parameters[0] == 2:
                rows.removeAll()
                row = 0
                column = 0
            case UInt8(ascii: "m"):
                setGraphicsRendition(parameters)
            case UInt8(ascii: "h") where isPrivate && parameters[0] == 33:
                iceColors = true
            case UInt8(ascii: "l") where isPrivate && parameters[0] == 33:
                iceColors = false
            case UInt8(ascii: "t") where parameters.count >= 4:
                let color = UInt32(parameters[1] & 0xFF) << 16 | UInt32(parameters[2] & 0xFF) << 8 | UInt32(parameters[3] & 0xFF)
                if parameters[0] == 0 {
                    background24 = color
                } else if parameters[0] == 1 {
                    foreground24 = color
                }
            default:
                break
            }
            return end
        }

        private mutating func setGraphicsRendition(_ parameters: [Int]) {
            for parameter in parameters {
                switch parameter {
                case 0:
                    foreground = 7
                    background = 0
                    foreground24 = nil
                    background24 = nil
                    bold = false
                    blink = false
                    inverse = false
                case 1:
                    bold = true
                    foreground |= 8
                    foreground24 = nil
                case 5:
                    blink = true
                    background24 = nil
                    if iceColors {
                        background |= 8
                    }
                case 7:
                    inverse = true
                case 22:
                    bold = false
                    foreground &= 7
                case 25:
                    blink = false
                    background &= 7
                case 27:
                    inverse = false
                case 30...37:
                    foreground = (parameter - 30) | (bold ? 8 : 0)
                    foreground24 = nil
                case 39:
                    foreground = 7 | (bold ? 8 : 0)
                    foreground24 = nil
                case 40...47:
                    background = (parameter - 40) | (blink && iceColors ? 8 : 0)
                    background24 = nil
                case 49:
                    background = blink && iceColors ? 8 : 0
                    background24 = nil
                case 90...97:
                    foreground = parameter - 90 + 8
                    foreground24 = nil
                case 100...107:
                    background = parameter - 100 + 8
                    background24 = nil
                default:
                    break
                }
            }
        }

        private mutating func put(_ byte: UInt8) {
            defer { column += 1 }
            guard row < maximumLines, column < columns else { return }

            if rows.count <= row {
                rows.append(contentsOf: repeatElement([], count: row + 1 - rows.count))
            }
            if rows[row].count <= column {
                rows[row].append(contentsOf: repeatElement(Self.blank, count: column + 1 - rows[row].count))
            }
            rows[row][column] = inverse
                ? Cell(byte: byte, foreground: TextArt.vgaPalette[(background & 7) | (foreground & 8)], background: TextArt.vgaPalette[foreground & 7])
                : Cell(byte: byte, foreground: foreground24 ?? TextArt.vgaPalette[foreground], background: background24 ?? TextArt.vgaPalette[background])
        }

        var art: TextArt {
            var colors: [UInt32: NSColor] = [:]
            func color(_ rgb: UInt32) -> NSColor {
                if let cached = colors[rgb] {
                    return cached
                }
                let created = TextArt.color(rgb)
                colors[rgb] = created
                return created
            }

            let lines = (rows.isEmpty ? [[]] : rows).map { cells -> [Run] in
                var runs: [Run] = []
                var runCell: Cell?
                var text = ""
                for cell in cells + repeatElement(Self.blank, count: max(columns - cells.count, 0)) {
                    if let previous = runCell, previous.foreground != cell.foreground || previous.background != cell.background {
                        runs.append(Run(text: text, foreground: color(previous.foreground), background: color(previous.background)))
                        text = ""
                    }
                    runCell = cell
                    text.append(TextArt.characters[Int(cell.byte)])
                }
                if let last = runCell {
                    runs.append(Run(text: text, foreground: color(last.foreground), background: color(last.background)))
                }
                return runs
            }
            return TextArt(lines: lines, columns: columns, background: color(TextArt.vgaPalette[0]))
        }
    }
}

final class TextArtLayoutManager: NSLayoutManager {

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count glyphCount: Int, font: NSFont, textMatrix: CGAffineTransform, attributes: [NSAttributedString.Key: Any] = [:], in context: CGContext) {
        for index in 0..<glyphCount {
            context.saveGState()
            context.clip(to: CGRect(x: positions[index].x, y: positions[index].y - font.pointSize * 2, width: SharedCode.nfoCellWidth, height: font.pointSize * 4))
            super.showCGGlyphs(glyphs + index, positions: positions + index, count: 1, font: font, textMatrix: textMatrix, attributes: attributes, in: context)
            context.restoreGState()
        }
    }
}

final class BitmapArtView: NSView {

    let art: TextArt.Bitmap

    init(art: TextArt.Bitmap) {
        self.art = art
        super.init(frame: NSRect(x: 0, y: 0, width: art.pixelWidth, height: art.pixelHeight))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let firstColumn = max(Int(dirtyRect.minX) / 8, 0)
        let lastColumn = min((Int(dirtyRect.maxX.rounded(.up)) + 7) / 8, art.columns)
        let firstRow = max(Int(dirtyRect.minY) / art.glyphHeight, 0)
        let lastRow = min((Int(dirtyRect.maxY.rounded(.up)) + art.glyphHeight - 1) / art.glyphHeight, art.rows)
        guard firstColumn < lastColumn, firstRow < lastRow,
              let context = NSGraphicsContext.current?.cgContext,
              let image = art.image(columns: firstColumn..<lastColumn, rows: firstRow..<lastRow) else { return }

        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(firstColumn * 8), y: CGFloat(lastRow * art.glyphHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }
}
