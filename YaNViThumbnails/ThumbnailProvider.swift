//
//  ThumbnailProvider.swift
//  YaNViThumbnails
//
//  Created by mackonsti@outlook.com on 25/4/2026.
//

import QuickLookThumbnailing
import AppKit
import CoreText

class ThumbnailProvider: QLThumbnailProvider {

    // Bundled font defined in SharedCode.swift

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        // Register bundled font using shared code
        SharedCode.registerFonts()

        // Check if the font actually loaded, otherwise quit thumbnail renderer
        if NSFont(name: SharedCode.nfoFontName, size: SharedCode.nfoFontSize) == nil {
            handler(nil, nil)
            return
        }

        // Get requested thumbnail size
        let maxThumSize = request.maximumSize

        // Calculate a document-like aspect ratio (A4, US Letter or US Legal):
        // By providing a thumbnail with a document aspect ratio, we signal to macOS
        // that this is a "Document" type, which helps trigger the "Page" decoration
        //
        // let A4Ratio: CGFloat = 1.0 / 1.414
        // let legalRatio: CGFloat = 8.5 / 14.0
        let letterRatio: CGFloat = 8.5 / 11.0

        var width = maxThumSize.width
        var height = width / letterRatio

        // Ensure the calculated dimensions stay within the system's requested maximum size
        if height > maxThumSize.height {
            height = maxThumSize.height
            width = height * letterRatio
        }

        // Define the thumbnail rendered image size
        let size = CGSize(width: width, height: height)

        // Create the reply object with the defined document-shaped size where
        // we use the context-based initializer to draw our text content manually
        let reply = QLThumbnailReply(contextSize: size) { context in

            // Define drawing rectangle (use ~99% of width and height)
            let insetX = size.width * 0.005
            let insetY = size.height * 0.005
            let drawRect = CGRect(x: insetX, y: insetY, width: size.width * 0.99, height: size.height * 0.99)

            // Check NFO file size first (Limit set to 2 MB to avoid crashes)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: request.fileURL.path),
               let fileSize = attributes[.size] as? UInt64 {
                if fileSize > 2_097_152 {
                    // Exit process and quit thumbnail renderer
                    return false
                }
            }

            guard let art = try? TextArt.load(from: request.fileURL, maximumLines: 500), art.columns > 0 else {
                return false
            }

            var page = NSColor.white.cgColor
            var ink = NSColor.black.cgColor
            NSAppearance(named: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                page = (art.background ?? .textBackgroundColor).cgColor
                ink = NSColor.textColor.cgColor
            }

            context.setFillColor(page)
            context.fill(CGRect(origin: .zero, size: size))

            let baseFont = CTFontCreateWithName(SharedCode.nfoFontName as CFString, SharedCode.nfoFontSize, nil)
            let charWidth = SharedCode.nfoCellWidth

            // Compute line height (tight, no leading)
            let descent = CTFontGetDescent(baseFont)
            let lineHeight = CTFontGetAscent(baseFont) + descent
            let cell = CGRect(x: 0, y: -descent, width: charWidth, height: lineHeight)

            let scale = drawRect.width / (CGFloat(art.columns) * charWidth)
            let visibleLines = min(art.lines.count, Int((drawRect.height / (lineHeight * scale)).rounded(.up)))
            let artHeight = CGFloat(visibleLines) * lineHeight

            var backgroundPaths: [CGColor: CGMutablePath] = [:]
            var foregroundPaths: [CGColor: CGMutablePath] = [:]
            var glyphPaths: [Character: CGPath?] = [:]

            for (row, line) in art.lines.prefix(visibleLines).enumerated() {
                let baseline = artHeight - CGFloat(row + 1) * lineHeight + descent
                var column = 0
                for run in line {
                    if let background = run.background {
                        Self.path(for: background.cgColor, in: &backgroundPaths).addRect(CGRect(
                            x: CGFloat(column) * charWidth,
                            y: baseline - descent,
                            width: CGFloat(run.text.count) * charWidth,
                            height: lineHeight
                        ))
                    }
                    let foreground = Self.path(for: run.foreground?.cgColor ?? ink, in: &foregroundPaths)
                    for character in run.text {
                        if let glyph = Self.glyphPath(for: character, font: baseFont, cell: cell, cache: &glyphPaths) {
                            foreground.addPath(glyph, transform: CGAffineTransform(translationX: CGFloat(column) * charWidth, y: baseline))
                        }
                        column += 1
                    }
                }
            }

            context.saveGState()
            context.clip(to: drawRect)
            context.translateBy(x: drawRect.minX, y: drawRect.maxY - artHeight * scale)
            context.scaleBy(x: scale, y: scale)

            for paths in [backgroundPaths, foregroundPaths] {
                for (color, path) in paths {
                    context.setFillColor(color)
                    context.addPath(path)
                    context.fillPath()
                }
            }

            // Restore context and return
            context.restoreGState()
            return true
        }

        // Return reply with the render
        handler(reply, nil)
    }

    private static func path(for color: CGColor, in paths: inout [CGColor: CGMutablePath]) -> CGMutablePath {
        if let path = paths[color] {
            return path
        }
        let path = CGMutablePath()
        paths[color] = path
        return path
    }

    private static func glyphPath(for character: Character, font: CTFont, cell: CGRect, cache: inout [Character: CGPath?]) -> CGPath? {
        if let cached = cache[character] {
            return cached
        }
        var units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        var path = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) ? CTFontCreatePathForGlyph(font, glyphs[0], nil) : nil
        if #available(macOS 13, *), let unclipped = path {
            path = unclipped.intersection(CGPath(rect: cell, transform: nil))
        }
        cache[character] = .some(path)
        return path
    }
}
