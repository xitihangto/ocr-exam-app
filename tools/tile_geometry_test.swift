// 预览格子几何回归测试（纯离屏渲染，不截图、不看外观，只输出数字）。
//
//   swift tools/tile_geometry_test.swift
//
// 干什么：用 `ImageRenderer` 在离屏画布上按真实宽度（546pt，卡片内容区）渲染
// 「6 栏 LazyVGrid + 横向大图缩略图」，然后沿中线扫像素，数一行里有多少个独立的格子、每个多宽。
//
// 为什么要有：用户 2026-10-29 报「横向图片贴进去会超出边界、与其他预览框大幅度重叠」。
// 根因是图片直接放进 `ZStack` 时，`.aspectRatio(contentMode: .fill)` 会把 **ZStack 自己**撑宽，
// 而 `.clipShape` 是在撑宽之后才裁的 —— 裁的边界已经是错的宽度，格子压到隔壁去了。
// 正解：用 `Color`（无限灵活、只接受父级给的宽度）撑尺寸，图片只作 `.overlay`。
//
// 期望输出（2026-10-29 实测）：
//   旧写法：一行只量到 **1** 个 546 宽的块（六格粘成一整条）
//   新写法：**6** 个格子，各 84–85 宽，间距 8，最右边界 = 画布宽 - 1
// 改完预览区布局后跑一次，新写法那几行必须还是 6 个、宽度 ~84。

import SwiftUI
import AppKit

// 一张横向大图（1200×600），模拟用户贴进来的横版试卷照片
let land: NSImage = {
    let s = NSSize(width: 1200, height: 600)
    let img = NSImage(size: s)
    img.lockFocus()
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(origin: .zero, size: s).fill()
    img.unlockFocus()
    return img
}()

let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

// 旧写法：图片直接塞在 ZStack 里
struct OldTile: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.93))
            Image(nsImage: land).resizable().aspectRatio(contentMode: .fill)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// 新写法：Color 撑尺寸，图片作 overlay
struct NewTile: View {
    var body: some View {
        Color(white: 0.93)
            .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82)
            .overlay { Image(nsImage: land).resizable().aspectRatio(contentMode: .fill) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor func measure<V: View>(_ v: V, _ label: String) {
    let r = ImageRenderer(content: v.frame(width: 546))
    r.scale = 1
    guard let img = r.nsImage,
          let rep = NSBitmapImageRep(data: img.tiffRepresentation!) else {
        print("\(label): 渲染失败"); return
    }
    let W = rep.pixelsWide, H = rep.pixelsHigh
    func dark(_ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return c.brightnessComponent < 0.85
    }
    let y = min(H / 2, H - 1)
    var segs: [(Int, Int)] = []; var s = -1
    for x in 0..<W {
        if dark(x, y) && s < 0 { s = x }
        if !dark(x, y) && s >= 0 { segs.append((s, x - 1)); s = -1 }
    }
    if s >= 0 { segs.append((s, W - 1)) }
    let real = segs.filter { $0.1 - $0.0 > 3 }
    print("\(label)：画布 \(W)×\(H)，一行里量到 \(real.count) 个格子")
    for g in real {
        print("    x \(g.0)..\(g.1)  宽 \(g.1 - g.0 + 1)")
    }
    if let last = real.last { print("    最右边界 \(last.1)（画布宽 \(W)）") }
}

MainActor.assumeIsolated {
    measure(LazyVGrid(columns: columns, spacing: 8) {
        ForEach(0..<6) { _ in OldTile() }
    }.background(Color.white), "旧写法")
    measure(LazyVGrid(columns: columns, spacing: 8) {
        ForEach(0..<6) { _ in NewTile() }
    }.background(Color.white), "新写法")
}
