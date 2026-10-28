// 生成「试卷识别」的图标母版：紫色渐变底 + 中间一份试卷。
//
// 用法：swift tools/make_icon.swift docs/icon/icon-master.png
//
// 为什么手绘而不是 AI 生图：图标要在 16px 还认得出，形状必须是干净的几何体；
// 生成图缩到 32px 以下常常糊成一团。这里全部用 CoreGraphics 画，任何尺寸都锐利。

import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "docs/icon/icon-master.png"

let S: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("建不出位图") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// MARK: - 底：紫罗兰渐变（右上浅 → 左下深），squircle 圆角

let canvas = NSRect(x: 0, y: 0, width: S, height: S)
let corner: CGFloat = 228
let bgPath = NSBezierPath(roundedRect: canvas, xRadius: corner, yRadius: corner)

NSGraphicsContext.saveGraphicsState()
bgPath.addClip()

let top = NSColor(srgbRed: 0.686, green: 0.451, blue: 0.996, alpha: 1)   // #AF73FE
let mid = NSColor(srgbRed: 0.545, green: 0.290, blue: 0.960, alpha: 1)   // #8B4AF5
let bottom = NSColor(srgbRed: 0.353, green: 0.106, blue: 0.729, alpha: 1) // #5A1BBA

if let grad = NSGradient(colors: [top, mid, bottom]) {
    // 角度 55°：从左下往右上推，和 macOS 图标常见的打光方向一致
    grad.draw(in: canvas, angle: 55)
}

NSGraphicsContext.restoreGraphicsState()

// MARK: - 试卷

let paperW: CGFloat = 524
let paperH: CGFloat = 704
let paper = NSRect(x: (S - paperW) / 2, y: (S - paperH) / 2 - 4, width: paperW, height: paperH)
let paperPath = NSBezierPath(roundedRect: paper, xRadius: 26, yRadius: 26)

// 投影：让纸从底色上"浮"起来
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0.10, alpha: 0.30)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
NSColor.white.setFill()
paperPath.fill()
NSGraphicsContext.restoreGraphicsState()

// 纸面极淡的暖白，纯白在紫底上会发青
NSColor(srgbRed: 1.0, green: 0.996, blue: 1.0, alpha: 1).setFill()
paperPath.fill()

// MARK: - 纸上的内容

let left = paper.minX + 52
let right = paper.maxX - 52

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
         _ color: NSColor, radius: CGFloat? = nil) {
    let r = NSRect(x: x, y: y, width: w, height: h)
    let p = radius.map { NSBezierPath(roundedRect: r, xRadius: $0, yRadius: $0) }
        ?? NSBezierPath(rect: r)
    color.setFill()
    p.fill()
}

// 标题条（紫，和底色呼应）
let titleGrad = NSGradient(colors: [
    NSColor(srgbRed: 0.545, green: 0.290, blue: 0.960, alpha: 1),
    NSColor(srgbRed: 0.408, green: 0.169, blue: 0.851, alpha: 1)
])
let titleRect = NSRect(x: paper.midX - 148, y: paper.maxY - 96, width: 296, height: 30)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: titleRect, xRadius: 15, yRadius: 15).addClip()
titleGrad?.draw(in: titleRect, angle: 0)
NSGraphicsContext.restoreGraphicsState()

// 副标题短条
bar(paper.midX - 88, paper.maxY - 128, 176, 14,
    NSColor(srgbRed: 0.72, green: 0.68, blue: 0.80, alpha: 1), radius: 7)

// 分隔线
bar(left, paper.maxY - 168, right - left, 4,
    NSColor(srgbRed: 0.88, green: 0.86, blue: 0.92, alpha: 1), radius: 2)

// 三道题：题号方块 + 题干线 + 选项框
let ink = NSColor(srgbRed: 0.36, green: 0.34, blue: 0.42, alpha: 1)
let faint = NSColor(srgbRed: 0.78, green: 0.76, blue: 0.84, alpha: 1)
let line = NSColor(srgbRed: 0.66, green: 0.63, blue: 0.74, alpha: 1)

var y = paper.maxY - 236
for i in 0..<3 {
    // 题号
    bar(left, y, 30, 30, ink, radius: 8)
    // 题干：长线 + 短线
    bar(left + 46, y + 15, right - left - 46 - CGFloat(i * 26), 16, line, radius: 8)
    bar(left + 46, y - 12, right - left - 46 - 96, 12, faint, radius: 6)
    // 选项：4 个小方框
    for k in 0..<4 {
        let box = NSRect(x: left + 46 + CGFloat(k) * 52, y: y - 58, width: 34, height: 34)
        let p = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        p.lineWidth = 3.2
        faint.setStroke()
        p.stroke()
    }
    y -= 150
}

// MARK: - 右下角一枚紫色小勾，点一下"识别完成"的意思

NSGraphicsContext.saveGraphicsState()
ctx.translateBy(x: paper.maxX - 92, y: paper.minY + 62)
let check = NSBezierPath()
check.move(to: NSPoint(x: -26, y: 2))
check.line(to: NSPoint(x: -8, y: -18))
check.line(to: NSPoint(x: 28, y: 20))
check.lineWidth = 13
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor(srgbRed: 0.545, green: 0.290, blue: 0.960, alpha: 1).setStroke()
check.stroke()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

// MARK: - 输出

try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outPath).deletingLastPathComponent(),
    withIntermediateDirectories: true)

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("✓ \(outPath)  \(png.count / 1024) KB")
