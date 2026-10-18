import SwiftUI
import UIKit

/// Assistant markdown for iOS. Elixir already sets `markdown` on the text node;
/// this view is what stock Mob `Text` does not do. Copy-all keeps the original
/// source. Image syntax is stripped before parse so nothing is fetched.
struct HandbeanMarkdownText: View {
    let source: String
    let streaming: Bool
    let fontSize: CGFloat
    let color: Color

    @StateObject private var pace: HandbeanMarkdownPace

    init(source: String, streaming: Bool, fontSize: CGFloat, color: Color) {
        self.source = source
        self.streaming = streaming
        self.fontSize = fontSize
        self.color = color
        _pace = StateObject(
            wrappedValue: HandbeanMarkdownPace(
                source: source,
                streaming: streaming,
                fontSize: fontSize,
                color: color
            )
        )
    }

    var body: some View {
        Text(pace.rendered)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .tint(Color(red: 0.12, green: 0.35, blue: 0.68))
            .environment(\.openURL, OpenURLAction { url in
                switch url.scheme?.lowercased() {
                case "http", "https":
                    return .systemAction
                default:
                    return .discarded
                }
            })
            .contextMenu {
                Button("复制全文") {
                    UIPasteboard.general.string = source
                }
            }
            .onAppear {
                pace.update(source: source, streaming: streaming, fontSize: fontSize, color: color)
            }
            .onChange(of: source) { _, _ in
                pace.update(source: source, streaming: streaming, fontSize: fontSize, color: color)
            }
            .onChange(of: streaming) { _, _ in
                pace.update(source: source, streaming: streaming, fontSize: fontSize, color: color)
            }
    }
}

@MainActor
final class HandbeanMarkdownPace: ObservableObject {
    @Published private(set) var rendered = AttributedString()

    private var latest: String
    private var streaming: Bool
    private var fontSize: CGFloat
    private var color: Color
    private var renderedSource: String?
    private var ticker: Task<Void, Never>?

    init(source: String, streaming: Bool, fontSize: CGFloat, color: Color) {
        latest = source
        self.streaming = streaming
        self.fontSize = fontSize
        self.color = color
        publish(source)
    }

    deinit {
        ticker?.cancel()
    }

    func update(source: String, streaming: Bool, fontSize: CGFloat, color: Color) {
        latest = source
        self.fontSize = fontSize
        self.color = color
        let wasStreaming = self.streaming
        self.streaming = streaming

        if !streaming {
            ticker?.cancel()
            ticker = nil
            publish(source)
            return
        }

        if renderedSource == nil || !wasStreaming {
            publish(source)
        }
        startTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard streaming, latest != renderedSource else { return }
        publish(latest)
    }

    private func publish(_ source: String) {
        rendered = HandbeanMarkdown.render(source, fontSize: fontSize, color: color)
        renderedSource = source
    }
}

enum HandbeanMarkdown {
    static func displaySource(_ raw: String) -> String {
        let withoutMarkdownImages = replace(raw, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, template: "$1")
        return replace(
            withoutMarkdownImages,
            pattern: #"<img\b[^>]*>"#,
            template: "",
            options: [.caseInsensitive]
        )
    }

    static func render(_ source: String, fontSize: CGFloat, color: Color) -> AttributedString {
        let display = displaySource(source)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var parsed = try? AttributedString(markdown: display, options: options) else {
            return AttributedString(display)
        }
        applyTypography(&parsed, fontSize: fontSize, color: color)
        return parsed
    }

    private static func applyTypography(
        _ parsed: inout AttributedString,
        fontSize: CGFloat,
        color: Color
    ) {
        for run in parsed.runs {
            let inline = run.inlinePresentationIntent
            if let level = headerLevel(run.presentationIntent) {
                let size = fontSize + CGFloat(max(0, 5 - level)) * 2
                parsed[run.range].font = .system(size: size, weight: .semibold)
            } else if isCodeBlock(run.presentationIntent) || inline?.contains(.code) == true {
                parsed[run.range].font = .system(size: fontSize, design: .monospaced)
            } else {
                var font = Font.system(size: fontSize, weight: inline?.contains(.stronglyEmphasized) == true ? .semibold : .regular)
                if inline?.contains(.emphasized) == true {
                    font = font.italic()
                }
                parsed[run.range].font = font
            }
            if inline?.contains(.strikethrough) == true {
                parsed[run.range].strikethroughStyle = .single
            }
            if run.link == nil {
                parsed[run.range].foregroundColor = color
            }
        }
    }

    private static func headerLevel(_ intent: PresentationIntent?) -> Int? {
        guard let intent else { return nil }
        for component in intent.components {
            if case .header(let level) = component.kind {
                return level
            }
        }
        return nil
    }

    private static func isCodeBlock(_ intent: PresentationIntent?) -> Bool {
        guard let intent else { return false }
        for component in intent.components {
            if case .codeBlock = component.kind {
                return true
            }
        }
        return false
    }

    private static func replace(
        _ raw: String,
        pattern: String,
        template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return raw
        }
        let range = NSRange(raw.startIndex..., in: raw)
        return expression.stringByReplacingMatches(
            in: raw,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
