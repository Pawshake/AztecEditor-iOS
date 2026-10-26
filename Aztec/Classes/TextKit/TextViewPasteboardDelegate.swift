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

    init(textView: TextView, identifier: UUID, matchingStyle: Bool) {
        self.textView = textView
        self.window = textView.window
        self.identifier = identifier
        self.matchingStyle = matchingStyle
        self.selectedRange = textView.selectedRange
        self.originalText = NSAttributedString(attributedString: textView.attributedText)
        self.wasFirstResponder = textView.isFirstResponder
        Self.trace("itemProviders begin")
        let providers = textView.pasteboard.itemProviders
        Self.trace("itemProviders returned count=\(providers.count)")
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
        Self.trace("candidate enumeration begin")
        self.candidates = ArraySlice(types.flatMap { type in
            providers.filter {
                Self.trace("conformance begin type=\(type)")
                let conforms = $0.hasItemConformingToTypeIdentifier(type)
                Self.trace("conformance returned type=\(type) result=\(conforms)")
                return conforms
            }
                .map { (provider: $0, type: type) }
        })
        Self.trace("candidate enumeration returned count=\(self.candidates.count)")
    }

    func start() {
        Self.trace("start validation begin")
        guard let textView = currentTextView else {
            Self.trace("start validation rejected")
            return
        }
        Self.trace("start validation returned")
        while let candidate = candidates.first, representations[candidate.type] != nil {
            candidates.removeFirst()
        }
        guard let candidate = candidates.popFirst() else {
            Self.trace("delegate insertion begin")
            textView.loadedPasteboardContent = LoadedPasteboardContent(representations: representations)
            let pasted: Bool
            if matchingStyle {
                pasted = textView.pasteboardDelegate.tryPastingString(in: textView)
            } else {
                pasted = textView.pasteboardDelegate.tryPasting(in: textView)
            }
            textView.loadedPasteboardContent = nil
            Self.trace("delegate insertion returned handled=\(pasted)")
            if textView.pendingPasteIdentifier == identifier {
                textView.pendingPasteIdentifier = nil
                if !pasted {
                    Self.trace("UIKit fallback begin")
                    textView.paste(itemProviders: providers)
                    Self.trace("UIKit fallback returned")
                }
            }
            return
        }
        Self.trace("loadDataRepresentation begin type=\(candidate.type)")
        candidate.provider.loadDataRepresentation(forTypeIdentifier: candidate.type) { data, error in
            Self.trace("provider callback type=\(candidate.type) hasData=\(data != nil) hasError=\(error != nil)")
            DispatchQueue.main.async {
                Self.trace("provider callback entered main type=\(candidate.type)")
                guard self.currentTextView != nil else { return }
                if let data = data {
                    self.representations[candidate.type] = data
                }
                self.start()
            }
        }
        Self.trace("loadDataRepresentation returned type=\(candidate.type)")
    }

    private static func trace(_ phase: String) {
        #if DEBUG
        NSLog("%@", "AZTEC_PASTE_TRACE \(phase) main=\(Thread.isMainThread)")
        #endif
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
