import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Rebuild the icon cleanly: key the champagne mark out of the source, then composite it at a
// chosen scale onto a freshly-drawn charcoal squircle (transparent corners, NO rim). Lets us
// dial mark size and recolour for the dev variant.
// usage: mockicon <source.png> <out.png> <size> <markFraction> <markHex|orig>
let a = CommandLine.arguments
guard a.count == 6,
      let srcCG = NSImage(contentsOfFile: a[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fputs("usage: mockicon src out size frac markHex|orig\n", stderr); exit(1) }
let outPath = a[2], size = Int(a[3])!, frac = Double(a[4])!, markArg = a[5].lowercased()

let W = srcCG.width, H = srcCG.height
var src = [UInt8](repeating: 0, count: W * H * 4)
CGContext(data: &src, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(srcCG, in: CGRect(x: 0, y: 0, width: W, height: H))

func lum(_ i: Int) -> Double { 0.299 * Double(src[i]) + 0.587 * Double(src[i+1]) + 0.114 * Double(src[i+2]) }
func warm(_ i: Int) -> Double { Double(src[i]) - Double(src[i+2]) }   // R-B: champagne warm, gray ~0
func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double { let t = max(0, min(1,(x-e0)/(e1-e0))); return t*t*(3-2*t) }

// bbox of the warm+light mark (excludes the neutral-gray outer margin)
var minX = W, minY = H, maxX = 0, maxY = 0
for y in 0..<H { for x in 0..<W {
    let i = (y*W + x)*4
    if lum(i) > 150 && warm(i) > 12 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) }
}}
let mW = maxX - minX + 1, mH = maxY - minY + 1

// optional recolour target
var tint: (Double,Double,Double)? = nil
if markArg != "orig" {
    let v = UInt32(markArg, radix: 16)!
    tint = (Double((v>>16)&255), Double((v>>8)&255), Double(v&255))
}
// build mark image (bbox-cropped), alpha keyed by luminance, AA edges preserved
var mark = [UInt8](repeating: 0, count: mW * mH * 4)
for y in 0..<mH { for x in 0..<mW {
    let s = ((minY+y)*W + (minX+x))*4, d = (y*mW + x)*4
    let al = smooth(110, 180, lum(s))
    guard al > 0 else { continue }
    var r = Double(src[s]), g = Double(src[s+1]), b = Double(src[s+2])
    if let (tr,tg,tb) = tint { let k = min(1.0, lum(s)/230.0); r = tr*k; g = tg*k; b = tb*k }
    mark[d] = UInt8(r); mark[d+1] = UInt8(g); mark[d+2] = UInt8(b); mark[d+3] = UInt8(al*255)
}}
let markCG = CGContext(data: &mark, width: mW, height: mH, bitsPerComponent: 8, bytesPerRow: mW*4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!  // premultiply on draw
// note: buffer is straight alpha; wrap as unassociated
let provider = CGDataProvider(data: Data(mark) as CFData)!
let markImg = CGImage(width: mW, height: mH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mW*4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
_ = markCG

// compose: charcoal squircle + centered mark
let s = CGFloat(size)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
let radius = s * 0.2237
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
// charcoal with a whisper of top sheen
let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0x30/255, green: 0x30/255, blue: 0x36/255, alpha: 1),
    CGColor(red: 0x18/255, green: 0x18/255, blue: 0x1c/255, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
// mark, scaled to `frac` of the icon by its longer side, centered
let scale = (s * CGFloat(frac)) / CGFloat(max(mW, mH))
let dw = CGFloat(mW) * scale, dh = CGFloat(mH) * scale
ctx.interpolationQuality = .high
ctx.draw(markImg, in: CGRect(x: (s-dw)/2, y: (s-dh)/2, width: dw, height: dh))

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)  mark bbox \(mW)x\(mH)  frac \(frac)")
