// Original LumaPath vector artwork. Coordinates use a 1024 × 1024 top-left canvas.
// Run from the repository root: swift Tools/Design/generate_icon.swift
import AppKit
import Foundation

let destination = CommandLine.arguments.dropFirst().first ?? "LumaPath/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)
var elements: [String] = []
func color(_ hex: String) -> CGColor {
    let value = UInt32(hex, radix: 16)!
    return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
// A tiny SVG path reader keeps the editable SVG and native raster identical.
func draw(_ data: String, _ fill: String) {
    let tokens = data.split(separator: " ").map(String.init)
    let path = CGMutablePath()
    var i = 0
    func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    func point() -> CGPoint { CGPoint(x: number(), y: number()) }
    while i < tokens.count {
        let command = tokens[i]; i += 1
        switch command {
        case "M": path.move(to: point())
        case "L": path.addLine(to: point())
        case "C": let a = point(), b = point(), c = point(); path.addCurve(to: c, control1: a, control2: b)
        case "Z": path.closeSubpath()
        default: fatalError("Unsupported path command: \(command)")
        }
    }
    context.setFillColor(color(fill)); context.addPath(path); context.fillPath()
    elements.append("  <path fill=\"#\(fill)\" d=\"\(data)\"/>")
}
let ink = "103C40", mint = "BDE9D5", cream = "FFF4CE", gold = "F4BD58"
draw("M 0 0 L 1024 0 L 1024 1024 L 0 1024 Z", ink)
// Handle: broad arch, with a real open center rather than a decorative circle.
draw("M 382 300 L 382 234 C 382 162 438 112 512 112 C 586 112 642 162 642 234 L 642 300 L 598 300 L 598 234 C 598 188 562 154 512 154 C 462 154 426 188 426 234 L 426 300 Z", mint)
// Shouldered roof and projecting eaves.
draw("M 338 292 C 378 280 410 252 430 230 L 594 230 C 614 252 646 280 686 292 L 718 336 C 722 343 718 352 708 352 L 316 352 C 306 352 302 343 306 336 Z", cream)
// Protective outer frame with bowed shoulders and substantial feet.
draw("M 318 374 L 362 374 L 334 706 C 330 750 362 780 406 780 L 618 780 C 662 780 694 750 690 706 L 662 374 L 706 374 L 736 710 C 742 780 692 824 626 824 L 398 824 C 332 824 282 780 288 710 Z", mint)
// Glass chamber, narrowing at the top and gently widening into the base.
draw("M 392 378 L 632 378 L 658 700 C 660 724 644 740 620 740 L 404 740 C 380 740 364 724 366 700 Z", cream)
// Warm side panes, divided by broad negative-space mullions.
draw("M 392 378 L 422 378 L 404 666 L 370 686 Z", gold)
draw("M 602 378 L 632 378 L 654 686 L 620 666 Z", gold)
// Flame: asymmetric, recognizable teardrop with an interior cut.
draw("M 515 398 C 520 448 572 460 566 508 C 562 542 537 562 509 562 C 477 562 454 540 457 510 C 459 486 482 470 484 446 C 495 455 500 466 499 480 C 522 459 524 432 515 398 Z", gold)
draw("M 514 494 C 514 510 535 517 530 533 C 525 548 500 549 494 535 C 488 522 505 510 514 494 Z", cream)
// The path emerges from the base, bends left, and returns toward the light.
draw("M 433 740 C 418 698 432 672 480 646 C 521 624 540 610 526 584 L 550 584 C 574 620 554 650 517 676 C 490 695 489 716 506 740 Z", ink)
// Grounding plinth and restrained brass inset.
draw("M 370 842 L 654 842 C 678 842 696 860 696 884 L 328 884 C 328 860 346 842 370 842 Z", cream)
draw("M 414 852 L 610 852 L 610 866 L 414 866 Z", gold)
// Four rays suggest illumination without competing with the lantern silhouette.
draw("M 230 366 L 250 344 L 292 388 L 272 410 Z", gold)
draw("M 182 476 L 190 446 L 260 464 L 252 494 Z", gold)
draw("M 774 344 L 794 366 L 752 410 L 732 388 Z", gold)
draw("M 834 446 L 842 476 L 772 494 L 764 464 Z", gold)
let url = URL(fileURLWithPath: destination)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">LumaPath lantern</title>
  <desc id="desc">A mint and ivory lantern with a golden flame and a winding path through its glass, on deep teal.</desc>
\(elements.joined(separator: "\n"))
</svg>

"""
try svg.write(toFile: "Tools/Design/lumapath-lantern.svg", atomically: true, encoding: .utf8)

// Publish compact PNGs for native brand lockups and the companion Watch icon.
func exportPNG(_ image: CGImage, to path: String, size: Int) throws {
    let target = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    target.interpolationQuality = .high
    target.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let targetURL = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try NSBitmapImageRep(cgImage: target.makeImage()!).representation(using: .png, properties: [:])!.write(to: targetURL)
}
let master = context.makeImage()!
let brandFolder = "LumaPath/App/Assets.xcassets/LumaBrand.imageset"
for (scale, size) in [(1, 96), (2, 192), (3, 288)] {
    try exportPNG(master, to: "\(brandFolder)/lantern@\(scale)x.png", size: size)
}
let brandContents = """
{"images":[{"filename":"lantern@1x.png","idiom":"universal","scale":"1x"},{"filename":"lantern@2x.png","idiom":"universal","scale":"2x"},{"filename":"lantern@3x.png","idiom":"universal","scale":"3x"}],"info":{"author":"xcode","version":1}}
"""
try brandContents.write(toFile: "\(brandFolder)/Contents.json", atomically: true, encoding: .utf8)
let watchFolder = "LumaPath/WatchApp/Assets.xcassets/AppIcon.appiconset"
try exportPNG(master, to: "\(watchFolder)/AppIcon.png", size: 1024)
try "{\"images\":[{\"filename\":\"AppIcon.png\",\"idiom\":\"universal\",\"platform\":\"watchos\",\"size\":\"1024x1024\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}".write(toFile: "\(watchFolder)/Contents.json", atomically: true, encoding: .utf8)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(toFile: "LumaPath/WatchApp/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
try FileManager.default.createDirectory(atPath: "docs/brand", withIntermediateDirectories: true)
try svg.write(toFile: "docs/brand/lumapath-icon.svg", atomically: true, encoding: .utf8)
// Transparent artwork retains its original colors for use on deep teal surfaces.
let transparent = svg.replacingOccurrences(of: elements[0] + "\n", with: "")
try transparent.write(toFile: "docs/brand/lumapath-mark-on-dark.svg", atomically: true, encoding: .utf8)
try exportPNG(master, to: "docs/brand/lumapath-icon.png", size: 512)
