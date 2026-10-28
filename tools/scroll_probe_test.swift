// 自绘滚动条的探针回归测试（纯离屏，不截图、不看外观，只输出数字）。
//
//   swift tools/scroll_probe_test.swift
//
// 背景：用户 2026-10-29 第 7 轮第 1 条报「预览区滚动条不滚动（超过 13 个文件时）」。
// 实测发现两种 SwiftUI 侧的做法都读不到滚动：
//   ① `.coordinateSpace(name:) + frame(in: .named(...))` —— 命名空间解析不出来，minY 恒 0；
//   ② `.frame(in: .global)` 两个探针相减 —— 滚动时 GeometryReader 根本不重新求值。
// 唯一可靠的是直接盯 ScrollView 背后的 `NSScrollView.contentView` 的 bounds 变化（本文件验证的就是它）。
//
// 期望输出：初始 0 → 滚到 90 后读到 90 → ✓ 探针跟上了
//
// 注意：脚本模式下 swift 解释器展不开 `@State` 宏（会报 "self is immutable"），
// 所以这里用普通 class 存状态，别改回 @State。

import SwiftUI
import AppKit

final class Probe { var offset: CGFloat = 0 }

/// 直接盯住 SwiftUI ScrollView 背后的 NSScrollView
struct ScrollOffsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { ReaderView(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReaderView)?.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (CGFloat) -> Void
        private weak var clip: NSView?
        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            guard let sv = enclosingScrollView else { print("⚠️ 找不到 NSScrollView"); return }
            let c = sv.contentView
            clip = c
            c.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                                   name: NSView.boundsDidChangeNotification, object: c)
            changed()
        }
        @objc func changed() {
            guard let clip else { return }
            onChange(clip.bounds.origin.y)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct TestView: View {
    let probe: Probe
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(0..<30) { _ in Rectangle().fill(Color.gray).frame(height: 82) }
            }
            .background(ScrollOffsetReader { probe.offset = $0 })
        }
        .frame(width: 300, height: 174)
    }
}

func findScrollView(_ v: NSView) -> NSScrollView? {
    if let s = v as? NSScrollView { return s }
    for sub in v.subviews { if let s = findScrollView(sub) { return s } }
    return nil
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
let host = NSHostingView(rootView: TestView(probe: probe))
host.frame = NSRect(x: 0, y: 0, width: 300, height: 174)
let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = host
win.orderFrontRegardless()
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
spin(0.6)
print("初始 offset = \(probe.offset)")
guard let sv = findScrollView(host) else { print("❌"); exit(2) }
sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: 90))
sv.reflectScrolledClipView(sv.contentView)
spin(0.4)
print("滚到 90 后 offset = \(probe.offset)")
let ok = abs(probe.offset - 90) < 2
print(ok ? "✓ 探针跟上了" : "❌ 没跟上")
exit(ok ? 0 : 1)
