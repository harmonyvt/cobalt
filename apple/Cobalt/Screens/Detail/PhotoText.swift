import Foundation
import ImageIO
import Vision

/// "copy text" of a photo (CONTRACT-GALLERY 1.19, Live Text if cheap): the words in the picture, read on this device with
/// Vision's text recognition. Nothing is sent anywhere. Lines come back top to bottom, one to a line.
enum PhotoText {
    /// The recognised text, or an empty string when there is none (or the file cannot be read).
    static func read(_ url: URL) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: url, options: [:])
            do { try handler.perform([request]) } catch { return "" }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
