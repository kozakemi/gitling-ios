import UIKit

/// A visual gutter, never inserted in the text storage or copied selection.
final class NumberedSourceTextView: UITextView {
    private(set) var lineStarts = [0]
    private(set) var showsLineNumbers = false
    private var numberedText: String?
    private var numberFont = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private var gutter: CGFloat = 0

    static func starts(in text: String) -> [Int] {
        let units = Array(text.utf16)
        var result = [0], index = 0
        while index < units.count {
            if units[index] == 13 {
                if index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                result.append(index + 1)
            } else if units[index] == 10 || units[index] == 0x2028 || units[index] == 0x2029 {
                result.append(index + 1)
            }
            index += 1
        }
        return result
    }

    func configureLineNumbers(_ enabled: Bool, pointSize: CGFloat) {
        if numberedText != text {
            numberedText = text
            lineStarts = Self.starts(in: text ?? "")
        }
        showsLineNumbers = enabled
        numberFont = .monospacedDigitSystemFont(ofSize: max(11, pointSize * 0.8), weight: .regular)
        let width = ceil((String(lineStarts.count) as NSString).size(withAttributes: [.font: numberFont]).width) + 20
        gutter = enabled ? width : 0
        if textContainerInset.left != gutter + 16 { textContainerInset.left = gutter + 16 }
        setNeedsDisplay()
    }

    override func layoutSubviews() { super.layoutSubviews(); setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard showsLineNumbers, let context = UIGraphicsGetCurrentContext() else { return }
        let x = contentOffset.x
        UIColor.secondarySystemBackground.setFill()
        context.fill(CGRect(x: x, y: contentOffset.y, width: gutter, height: bounds.height))
        let visible = CGRect(x: 0, y: contentOffset.y - textContainerInset.top, width: bounds.width, height: bounds.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [self] fragment, _, _, range, _ in
            let character = layoutManager.characterIndexForGlyph(at: range.location)
            // Binary search avoids scanning all source lines on every scroll.
            var low = 0, high = lineStarts.count
            while low < high {
                let mid = (low + high) / 2
                if lineStarts[mid] < character { low = mid + 1 } else { high = mid }
            }
            guard low < lineStarts.count, lineStarts[low] == character else { return }
            drawNumber(low + 1, at: fragment.minY + textContainerInset.top, x: x)
        }
        if text.isEmpty || lineStarts.last == (text as NSString).length {
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.height > 0 { drawNumber(lineStarts.count, at: fragment.minY + textContainerInset.top, x: x) }
        }
    }

    private func drawNumber(_ value: Int, at y: CGFloat, x: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .right
        (String(value) as NSString).draw(in: CGRect(x: x + 4, y: y + max(0, ((font?.lineHeight ?? numberFont.lineHeight) - numberFont.lineHeight) / 2), width: gutter - 12, height: numberFont.lineHeight + 2), withAttributes: [.font: numberFont, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style])
    }
}
