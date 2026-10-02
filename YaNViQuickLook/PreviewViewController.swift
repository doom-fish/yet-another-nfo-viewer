//
//  PreviewViewController.swift
//  YaNViQuickLook
//
//  Created by mackonsti@outlook.com on 7/3/2026.
//

import Cocoa
import QuickLookUI
import CoreText

class PreviewViewController: NSViewController, QLPreviewingController {

    @IBOutlet var textView: NSTextView!

    private var scrollView: NSScrollView?

    // Bundled font defined in SharedCode.swift

    override var acceptsFirstResponder: Bool {
        return false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        textView.textContainer?.replaceLayoutManager(TextArtLayoutManager())
        scrollView = textView.enclosingScrollView
        scrollView?.hasHorizontalScroller = true
        scrollView?.drawsBackground = true
        scrollView?.allowsMagnification = true
        scrollView?.minMagnification = 0.01
        scrollView?.maxMagnification = 16

        // Set the view properties
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = true

        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.allowsUndo = false

        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor

        textView.layoutManager?.usesFontLeading = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        print("YaNVi QuickLook view did load")
    }


    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {

        print("\nQuickLook extension loaded for:", url.lastPathComponent)

        // Ensure the bundled DOS font is available
        SharedCode.registerFonts()

        // Safely load the DOS font to avoid crashes
        struct QLError: Error { let message: String }

        // guard let nfoFont = NSFont(name: SharedCode.nfoFontName, size: SharedCode.nfoFontSize) else {
        //     throw QLError(message: "DOS font failed to load")
        // }

        // Fallback to the system's default monospace font instead
        let nfoFont = NSFont(name: SharedCode.nfoFontName, size: SharedCode.nfoFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: SharedCode.nfoFontSize, weight: .regular)

        // Check NFO file size first (Limit set to 2 MB to avoid crashes)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? UInt64 {
            if fileSize > 2_097_152 {
                // Exiting process should display a generic "Preview not available" by macOS
                handler(QLError(message: "File is too large to preview."))
                return
            }
        }

        let art: TextArt
        do {
            art = try TextArt.load(from: url)
        } catch {
            handler(error)
            return
        }
        let finalLineCount = art.lines.count
        let longestLine = art.columns

        print("NFO count: \(finalLineCount) lines @ maximum \(longestLine) chars")

        DispatchQueue.main.async { [self] in

            // Reset layout from previous preview
            textView.string = ""
            textView.layoutManager?.invalidateLayout(
                 forCharacterRange: NSRange(location: 0, length: 0),
                 actualCharacterRange: nil
            )

            // Configure text view
            textView.font = nfoFont
            textView.textStorage?.setAttributedString(art.attributedString(font: nfoFont))
            textView.backgroundColor = art.background ?? .textBackgroundColor
            scrollView?.backgroundColor = art.background ?? .textBackgroundColor
            scrollView?.documentView = art.bitmap.map(BitmapArtView.init(art:)) ?? textView
            scrollView?.magnification = 1

            // Find true line height used by AppKit
            let lineHeight: CGFloat
            if let layoutManager = textView.layoutManager {
                lineHeight = ceil(layoutManager.defaultLineHeight(for: nfoFont))
            } else {
                // Fallback: derive line height from the font's own metrics
                lineHeight = ceil(nfoFont.ascender + abs(nfoFont.descender) + nfoFont.leading)
            }

            // Calculate ASCII art size
            let contentSize = art.contentSize(lineHeight: lineHeight)
            let textWidth = contentSize.width
            let textHeight = contentSize.height

            print("View metrics: \(textWidth) x \(textHeight) pixels")

            // Disable wrapping
            textView.textContainer?.containerSize = NSSize(
                width: textWidth,
                height: textHeight + SharedCode.nfoMargin
            )

            // Request QuickLook panel size
            self.preferredContentSize = NSSize(
                width: textWidth + SharedCode.nfoMargin,
                height: textHeight
            )

            handler(nil)
        }
    }
}
