import AppKit

struct TextArt {

    struct Run {
        var text: String
        var foreground: NSColor? = nil
        var background: NSColor? = nil
    }

    var lines: [[Run]]
    var columns: Int
    var background: NSColor?

    static func load(from url: URL, maximumLines: Int = 100_000) throws -> TextArt {
        let bytes = [UInt8](try Data(contentsOf: url))
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

        static let palette: [UInt32] = [
            0x000000, 0xAA0000, 0x00AA00, 0xAA5500, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
            0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF
        ]

        static let blank = Cell(byte: 0x20, foreground: palette[7], background: palette[0])

        static let characters: [Character] = (0...255).map { byte in
            guard byte >= 0x20, byte != 0x7F,
                  let decoded = String(bytes: [UInt8(byte)], encoding: SharedCode.nfoEncoding()) else { return " " }
            return Character(decoded)
        }

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
                ? Cell(byte: byte, foreground: Self.palette[(background & 7) | (foreground & 8)], background: Self.palette[foreground & 7])
                : Cell(byte: byte, foreground: foreground24 ?? Self.palette[foreground], background: background24 ?? Self.palette[background])
        }

        var art: TextArt {
            var colors: [UInt32: NSColor] = [:]
            func color(_ rgb: UInt32) -> NSColor {
                if let cached = colors[rgb] {
                    return cached
                }
                let created = NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
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
                    text.append(Self.characters[Int(cell.byte)])
                }
                if let last = runCell {
                    runs.append(Run(text: text, foreground: color(last.foreground), background: color(last.background)))
                }
                return runs
            }
            return TextArt(lines: lines, columns: columns, background: color(Self.palette[0]))
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
