import UIKit

open class AztecTextViewPasteboardDelegate: TextViewPasteboardDelegate {

    public init() {}

    /// Tries to paste whatever is on the pasteboard into the editor.
    ///
    /// - Returns: True if the paste succeeds, false if it does not.
    ///
    open func tryPasting(in textView: TextView) -> Bool {
        return tryPastingURL(in: textView)
            || tryPastingHTML(in: textView)
            || tryPastingAttributedString(in: textView)
            || tryPastingString(in: textView)
    }

    /// Tries to paste a URL from the clipboard as a link applied to the selected range.
    ///
    /// - Returns: True if the paste succeeds, false if it does not.
    ///
    open func tryPastingURL(in textView: TextView) -> Bool {
        guard textView.pasteboardContent.hasURLs,
            let url = textView.pasteboardContent.url else {
                return false
        }

        let selectedRange = textView.selectedRange

        if selectedRange.length == 0 {
            guard textView.shouldChangeText(in: selectedRange, with: url.absoluteString) else {
                return true
            }
            textView.setLink(url, title:url.absoluteString, inRange: selectedRange)
        } else {
            textView.setLink(url, inRange: selectedRange)
        }

        return true
    }
    
    /// Tries to paste HTML from the clipboard as source, replacing the selected range.
    ///
    /// - Returns: True if the paste succeeds, false if it does not.
    ///
    open func tryPastingHTML(in textView: TextView) -> Bool {
        guard let html = textView.pasteboardContent.html(),
            textView.storage.htmlConverter.isSupported(html) else {
                return false
        }
        let string = textView.storage.htmlConverter.attributedString(from: html)
        guard textView.shouldChangeText(in: textView.selectedRange, with: string.string) else {
            return true
        }

        textView.replace(textView.selectedRange, withHTML: html)
        return true
    }

    /// Tries to paste an attributed string from the clipboard as source, replacing the selected range.
    ///
    /// - Returns: True if the paste succeeds, false if it does not.
    ///
    open func tryPastingAttributedString(in textView: TextView) -> Bool {
        guard let string = textView.pasteboardContent.attributedString() else {
            return false
        }
        string.loadLazyAttachments()
        let selectedRange = textView.selectedRange

        guard textView.shouldChangeText(in: selectedRange, with: string.string) else {
            return true
        }

        let storage = textView.storage

        let finalRange = NSRange(location: selectedRange.location, length: string.length)
        let originalText = textView.attributedText.attributedSubstring(from: selectedRange)

        textView.undoManager?.registerUndo(withTarget: textView, handler: { [weak textView] target in
            textView?.undoTextReplacement(of: originalText, finalRange: finalRange)
        })

        let colorCorrectedString = fixColors(in: string, using: textView.defaultTextColor)

        storage.replaceCharacters(in: selectedRange, with: colorCorrectedString)
        textView.notifyTextViewDidChange()

        let newSelectedRange = NSRange(location: selectedRange.location + string.length, length: 0)
        textView.selectedRange = newSelectedRange

        return true
    }

    private func fixColors(in string: NSAttributedString, using baseColor: UIColor?) -> NSAttributedString {
        guard #available(iOS 13.0, *) else {
            return string
        }
        let colorToUse = baseColor ?? UIColor.label

        let newString = NSMutableAttributedString(attributedString: string)
        newString.enumerateAttributes(in: newString.rangeOfEntireString, options: []) { (attributes, range, stop) in
            if attributes[.foregroundColor] == nil {
                newString.setAttributes([.foregroundColor: colorToUse], range: range)
            }
        }
        return newString
    }

    /// Tries to paste raw text from the clipboard, replacing the selected range.
    ///
    /// - Returns: True if the paste succeeds, false if it does not.
    ///
    open func tryPastingString(in textView: TextView) -> Bool {
        guard let string = textView.pasteboardContent.attributedString() else {
            return false
        }

        let selectedRange = textView.selectedRange

        guard textView.shouldChangeText(in: selectedRange, with: string.string) else {
            return true
        }

        let finalRange = NSRange(location: selectedRange.location, length: string.length)
        let originalText = textView.attributedText.attributedSubstring(from: selectedRange)

        textView.undoManager?.registerUndo(withTarget: textView, handler: { [weak textView] target in
            textView?.undoTextReplacement(of: originalText, finalRange: finalRange)
        })

        let newString = NSMutableAttributedString(attributedString: string)

        string.enumerateAttributes(in: string.rangeOfEntireString, options: []) { (attributes, range, stop) in
            let newAttributes = attributes.filter({ (key, value) -> Bool in
                return value is NSTextAttachment
            })

            newString.setAttributes(newAttributes, range: range)
        }

        newString.addAttributes(textView.typingAttributes, range: string.rangeOfEntireString)
        newString.loadLazyAttachments()

        textView.storage.replaceCharacters(in: selectedRange, with: newString)
        textView.notifyTextViewDidChange()

        let newSelectedRange = NSRange(location: selectedRange.location + newString.length, length: 0)
        textView.selectedRange = newSelectedRange

        return true
    }

}

final class PendingPaste {
    private weak var textView: TextView?
    private weak var window: UIWindow?
    private let identifier: UUID
    private let matchingStyle: Bool
    private let selectedRange: NSRange
    private let originalText: NSAttributedString
    private let wasFirstResponder: Bool
    private let providers: [NSItemProvider]
    private var candidates: ArraySlice<(provider: NSItemProvider, type: String)>
    private var representations = [String: Data]()

    init(textView: TextView, identifier: UUID, matchingStyle: Bool, providers: [NSItemProvider]) {
        self.textView = textView
        self.window = textView.window
        self.identifier = identifier
        self.matchingStyle = matchingStyle
        self.selectedRange = textView.selectedRange
        self.originalText = NSAttributedString(attributedString: textView.attributedText)
        self.wasFirstResponder = textView.isFirstResponder
        self.providers = providers

        var types = [NSAttributedString.pasteboardUTI.identifier,
                     UIPasteboard.UTType.RTFDText.identifier,
                     UIPasteboard.UTType.RTFText.identifier,
                     UIPasteboard.UTType.richText.identifier,
                     UIPasteboard.UTType.plainText.identifier]
        if !matchingStyle {
            types.insert(contentsOf: [UIPasteboard.UTType.URL.identifier,
                                      UIPasteboard.UTType.html.identifier], at: 0)
        }
        self.candidates = ArraySlice(types.flatMap { type in
            providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
                .map { (provider: $0, type: type) }
        })
    }

    func start() {
        guard let textView = currentTextView else { NSLog("AZTEC_FLOW start stale"); return }
        while let candidate = candidates.first, representations[candidate.type] != nil {
            candidates.removeFirst()
        }
        guard let candidate = candidates.popFirst() else {
            NSLog("%@", "AZTEC_FLOW finish types=\(representations.mapValues { $0.count })")
            textView.loadedPasteboardContent = LoadedPasteboardContent(representations: representations)
            let pasted: Bool
            if matchingStyle {
                pasted = textView.pasteboardDelegate.tryPastingString(in: textView)
            } else {
                pasted = textView.pasteboardDelegate.tryPasting(in: textView)
            }
            textView.loadedPasteboardContent = nil
            if textView.pendingPasteIdentifier == identifier {
                textView.pendingPasteIdentifier = nil
                if !pasted {
                    textView.paste(itemProviders: providers)
                }
            }
            return
        }
        NSLog("%@", "AZTEC_FLOW request type=\(candidate.type)")
        let didLoad: (Data?) -> Void = { data in
            NSLog("%@", "AZTEC_FLOW response type=\(candidate.type) bytes=\(data?.count ?? -1)")
            DispatchQueue.main.async {
                guard self.currentTextView != nil else { NSLog("AZTEC_FLOW response stale"); return }
                if let data = data {
                    self.representations[candidate.type] = data
                }
                self.start()
            }
        }
        candidate.provider.loadDataRepresentation(forTypeIdentifier: candidate.type) { data, _ in
            guard data == nil, candidate.type == UIPasteboard.UTType.plainText.identifier else {
                didLoad(data)
                return
            }
            candidate.provider.loadObject(ofClass: String.self) { string, _ in
                didLoad(string.map { Data($0.utf8) })
            }
        }
    }

    private var currentTextView: TextView? {
        guard let textView = textView,
              textView.pendingPasteIdentifier == identifier,
              textView.window === window,
              textView.isFirstResponder == wasFirstResponder,
              textView.selectedRange == selectedRange,
              textView.attributedText.isEqual(to: originalText) else {
            return nil
        }
        return textView
    }
}
