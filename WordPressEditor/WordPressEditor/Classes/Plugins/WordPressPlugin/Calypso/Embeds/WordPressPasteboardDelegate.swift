import UIKit
import Aztec

class WordPressTextViewPasteboardDelegate: AztecTextViewPasteboardDelegate {

    override func tryPastingURL(in textView: TextView) -> Bool {

        let selectedRange = textView.selectedRange

        guard let url = textView.pasteboardURL,
            selectedRange.length == 0,
            EmbedURLProcessor(url: url).isValidEmbed
            else {
                return super.tryPastingURL(in: textView)
        }

        let result = super.tryPastingString(in: textView)
        if result {
            // Bump the input to the next line – we need the embed link to be the only
            // text on this line – otherwise it can't be autoconverted.
            textView.insertText(String(.lineSeparator))
        }

        return result
    }
}
