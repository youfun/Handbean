// Run from mobile/: swift script/generate_ios_icons.swift
// Rasterize the Android vector mark into opaque iOS icons. The mark is one
// even-odd path; the seam is a hole.
import Foundation
import CoreGraphics
import ImageIO

final class VectorReader: NSObject, XMLParserDelegate {
    var path = ""
    var color = ""
    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if element == "path" {
            path = attributes["android:pathData"]!
            color = attributes["android:fillColor"]!
        }
    }
}

func color(_ hex: String) -> CGColor {
    let rgb = UInt32(hex.dropFirst(), radix: 16)!
    let components: [CGFloat] = [
        CGFloat((rgb >> 16) & 255) / 255,
        CGFloat((rgb >> 8) & 255) / 255,
        CGFloat(rgb & 255) / 255,
        1
    ]
    // Create the color in sRGB. The unqualified CGColor initializer uses the
    // display space, which shifts these values when drawn into an sRGB bitmap.
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
}

let resources = "android/app/src/main/res"
let reader = VectorReader()
let parser = XMLParser(contentsOf: URL(fileURLWithPath: "\(resources)/drawable/ic_launcher_foreground.xml"))!
parser.delegate = reader
precondition(parser.parse(), "Cannot read Android icon vector")
let colors = try String(contentsOfFile: "\(resources)/values/launcher_colors.xml", encoding: .utf8)
let background = colors.components(separatedBy: "<color name=\"ic_launcher_background\">")[1]
    .components(separatedBy: "</color>")[0]

// The shared mark consists of absolute M/L/Z commands on a 108 × 108 canvas.
let mark = CGMutablePath()
for token in reader.path.split(whereSeparator: { $0.isWhitespace }) {
    let command = token.first!
    if command == "Z" {
        mark.closeSubpath()
    } else {
        precondition(command == "M" || command == "L", "Unsupported vector command")
        let xy = token.dropFirst().split(separator: ",").map { Double($0)! }
        let point = CGPoint(x: xy[0], y: 108 - xy[1])
        if command == "M" { mark.move(to: point) } else { mark.addLine(to: point) }
    }
}

func drawMark(context: CGContext, pixels: Int) {
    context.setFillColor(color(background))
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.saveGState()
    context.scaleBy(x: CGFloat(pixels) / 108, y: CGFloat(pixels) / 108)
    context.addPath(mark)
    context.setFillColor(color(reader.color))
    context.fillPath(using: .evenOdd)
    context.restoreGState()
}

func writePNG(_ image: CGImage, to path: String) {
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "PNG export failed: \(path)")
}

let catalog = "ios/Assets.xcassets"
let output = "\(catalog)/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
var rendered = Set<Int>()
let slots: [(String, Double, [Int])] = [
    ("iphone", 20, [2, 3]), ("iphone", 29, [2, 3]),
    ("iphone", 40, [2, 3]), ("iphone", 60, [2, 3]),
    ("ipad", 20, [1, 2]), ("ipad", 29, [1, 2]),
    ("ipad", 40, [1, 2]), ("ipad", 76, [1, 2]),
    ("ipad", 83.5, [2]), ("ios-marketing", 1024, [1])
]
for (idiom, size, scales) in slots {
    for scale in scales {
        let pixels = Int(size * Double(scale))
        let filename = "icon_\(pixels).png"
        let points = size == floor(size) ? String(Int(size)) : String(size)
        images.append(["idiom": idiom, "size": "\(points)x\(points)",
                       "scale": "\(scale)x", "filename": filename])
        guard rendered.insert(pixels).inserted else { continue }
        let context = CGContext(data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        drawMark(context: context, pixels: pixels)
        writePNG(context.makeImage()!, to: "\(output)/\(filename)")
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(output)/Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(catalog)/Contents.json"))
print("Generated \(rendered.count) opaque iOS icon PNGs in \(output)")
