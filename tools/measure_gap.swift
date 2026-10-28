// 量「Word 试卷卡底部 → 窗口内容底部」的距离（单位 pt）。
//
// 用法：
//   swift tools/measure_gap.swift            # 自动找「试卷识别」的窗口，截图并测量
//   swift tools/measure_gap.swift shot.png   # 直接量一张已经截好的窗口图
//
// 只在需要精确对齐时用（用户 2026-10-29 临时授权过一次）。默认流程不做截图自检。

import AppKit
import CoreGraphics

/// 取「试卷识别」主窗口的 window id + 全局 bounds（点，左上原点）
///
/// 注意：App 里还挂着一个**隐形的 WKWebView 窗口**（alpha=0），它也是 layer 0、
/// 尺寸也大于 400×400，第一次会先被它匹配到，截出来全黑。所以这里不取「第一个」，
/// 而是取**宽度最接近主窗口 620pt** 的那个。
func findWindow() -> (id: CGWindowID, rect: CGRect)? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var best: (id: CGWindowID, rect: CGRect, delta: CGFloat)?
    for info in list {
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              owner.contains("试卷识别") || owner.contains("ExamOCR"),
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let w = bounds["Width"], let h = bounds["Height"], w > 400, h > 400
        else { continue }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: w, height: h)
        let delta = abs(w - 620)
        if best == nil || delta < best!.delta {
            best = (id, rect, delta)
        }
    }
    guard let b = best else { return nil }
    return (b.id, b.rect)
}

func capture(windowID: CGWindowID, to path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -o 不要阴影，-x 不发声
    p.arguments = ["-x", "-o", "-l\(windowID)", path]
    try? p.run()
    p.waitUntilExit()
}

/// 沿中心列从下往上扫，找第一处「明显比背景暗」的像素 —— 那就是 Word 卡的下边框。
func analyze(_ path: String, windowHeight: CGFloat) {
    guard let img = NSImage(contentsOfFile: path),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        print("❌ 读不出图：\(path)")
        exit(2)
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let scale = CGFloat(h) / windowHeight
    print("图像 \(w)×\(h)，窗口高 \(windowHeight)pt，倍率 \(String(format: "%.2f", scale))")

    func luma(_ x: Int, _ y: Int) -> Double {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    // 背景基准：取窗口最底部一行中间几个点（那里一定是背景）
    var bg = 0.0
    for x in stride(from: w / 2 - 20, through: w / 2 + 20, by: 4) {
        bg += luma(x, h - 2)
    }
    bg /= 11
    print(String(format: "背景亮度 %.3f", bg))

    // 中心列 + 左右各 1/4 处各扫一次，取最高的那条边（防止某个列正好压在文字空隙里）
    var found: [Int] = []
    for x in [w / 2, w / 4, w * 3 / 4] {
        var y = h - 1
        while y > 0 {
            if luma(x, y) < bg - 0.045 { break }
            y -= 1
        }
        if y > 0 { found.append(y) }
    }
    guard let edge = found.min() else {
        print("❌ 没找到卡片下边缘（整列都是背景？）")
        exit(3)
    }
    // 注意：位图 y=0 在顶部，所以「距底部」= h - 1 - edge
    let gapPx = CGFloat(h - 1 - edge)
    print(String(format: "卡片下边缘 y=%d（自顶部），距底 %.1f px = %.1f pt",
                 edge, gapPx, gapPx / scale))
}

let args = CommandLine.arguments
if args.count > 1 {
    analyze(args[1], windowHeight: 720 + 28)
} else {
    guard let win = findWindow() else {
        print("❌ 没找到「试卷识别」的窗口，先把它打开")
        exit(1)
    }
    print("窗口 id=\(win.id)  bounds=\(win.rect)")
    let tmp = "/tmp/exam_gap.png"
    capture(windowID: win.id, to: tmp)
    analyze(tmp, windowHeight: win.rect.height)
}
