import SwiftUI
import AppKit
import QuickLookUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - 品牌色

/// 试用版 Liquid Glass（本地试用，不升版、不推 GitHub，用户 2026-10-26 特别交代先本地跑看效果）。
/// 只给上传卡用：macOS 26+ 走玻璃，旧系统自动回退到现有的实色卡片 + 阴影。
extension View {
    @ViewBuilder func trialGlassCard(cornerRadius: CGFloat, shadowOpacity: Double, shadowRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 4)
            )
        }
    }
    /// 带 tint 的玻璃按钮：26+ 走玻璃 + tint，旧系统走原来的填充 + 阴影。
    @ViewBuilder func trialGlassTinted(cornerRadius: CGFloat, tint: Color, fallback: AnyShapeStyle, shadowColor: Color, shadowRadius: CGFloat, shadowY: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fallback)
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
            )
        }
    }
    /// 玻璃小药丸：26+ 走玻璃胶囊，旧系统走原来的胶囊填充。
    @ViewBuilder func trialGlassCapsule(fallbackFill: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(Capsule().fill(fallbackFill))
        }
    }
    /// 退出确认框的按钮样式：26+ 走系统玻璃按钮，旧系统走原来的 bordered。
    /// 两个按钮用同一个样式，系统 hover 才完全一样；不要再在上面叠自定义
    /// onHover + 放大 + 提亮 + 手型光标，那是取消按钮闪黑闪白、边缘手/箭头
    /// 来回跳的根源（玻璃材质重算 + 双重 hover 处理）。
    @ViewBuilder func dialogGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
    /// 主操作按钮：26+ 走系统玻璃 prominent，旧系统走 borderedProminent。
    /// 取消保持上面的 .glass。方案 2 的自定义 plain + tint 玻璃已删：
    /// 它和取消的系统玻璃是两个世界的产物，用户 2026-10-26 否决。
    /// 主按钮 hover 只叠黑 0.06 变深，和取消的系统 hover 逻辑统一，按下状态不动。
    @ViewBuilder func dialogGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

extension Color {
    /// 主强调色 = 图标那支紫。按钮、选中态、链接都用它。
    static let brandAccent = Color(red: 0.49, green: 0.24, blue: 0.93)   // #7D3DED
    static let brandPurple = Color(red: 0.66, green: 0.42, blue: 0.98)   // #A96BFA
    static let brandPink = Color(red: 0.85, green: 0.35, blue: 0.62)
    static let brandRed = Color(red: 0.91, green: 0.30, blue: 0.38)
}

@main
struct ExamApp: App {
    @StateObject private var state = AppState()

    init() {
        // 自检模式：不启动界面，只验证包内资源与类型白名单
        if CommandLine.arguments.contains("--selftest") {
            print("bundle   = \(Bundle.main.bundlePath)")
            print("rule     = \(AppState.bundledRule?.path ?? "❌ 未找到")")
            print("rule2    = \(AppState.bundledHandwritingRule?.path ?? "❌ 未找到")")
            print("docTypes = \(AppState.uploadTypes.map { $0.identifier }.joined(separator: ", "))")
            let rule = AppState.bundledRule.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            print("ruleHead = \(rule?.prefix(40).replacingOccurrences(of: "\n", with: " ") ?? "❌ 读不出")")
            print("python   = \(PythonRunner.executable?.path ?? "❌ 未找到")")
            print("pySize   = \(PythonRunner.sizeDescription)")
            exit(0)
        }

        // 自检：base64 分片注入到底多慢（--feedperftest）
        if CommandLine.arguments.contains("--feedperftest") {
            FeedPerfTest.run()
            exit(0)
        }

        // 自检：剪贴板图片落盘（--pastetest）
        if CommandLine.arguments.contains("--pastetest") {
            let image = AppState.demoImages(1)[0]
            let item = UploadItem(image: image, name: "剪贴板图片1")
            let exists = item.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let line = "paste url=\(item.url?.path ?? "nil")  name=\(item.name)  size=\(item.sizeKB)KB  exists=\(exists)\n"
            FileHandle.standardError.write(Data(line.utf8))
            exit(exists ? 0 : 1)
        }

        // 自检：批量建卡片的耗时（--batchperftest）
        // 用户 2026-10-29 第 8 轮报「10 个文件以上很卡」。这里造 12 张 2400×3200 的 JPEG
        // （接近手机拍照 / 扫描件的量级），量一量现在把 12 个 URL 变成预览卡片要多久。
        if CommandLine.arguments.contains("--batchperftest") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("batch-perf-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let w = 2400, h = 3200
            var urls: [URL] = []
            for i in 0..<12 {
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { continue }
                // 白底 + 若干横线 + 随编号变化的灰块，保证 12 张内容各不相同（不会被判重拦掉）
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 0.35 + Double(i) * 0.02, alpha: 1))
                for row in 0..<40 {
                    ctx.fill(CGRect(x: 200, y: h - 300 - row * 70,
                                    width: w - 400 - (row % 5) * 60, height: 12))
                }
                guard let cg = ctx.makeImage() else { continue }
                let url = dir.appendingPathComponent("page-\(i + 1).jpg")
                if let data = NSBitmapImageRep(cgImage: cg)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    try? data.write(to: url)
                    urls.append(url)
                }
            }

            let t0 = Date()
            let built = AppState.buildItems(from: urls)
            let dt = Date().timeIntervalSince(t0)

            // 分项：判重（读头尾 128KB + SHA-256）单独计时。
            // 用来回答「判重改成比文件路径会不会更快」—— 先看清它本来占多少。
            let t1 = Date()
            for url in urls { _ = UploadItem.fingerprint(ofFileAt: url) }
            let hashMS = Date().timeIntervalSince(t1) * 1000

            // 分项：只做缩略图（不含判重）
            let t2 = Date()
            for url in urls { _ = UploadItem.makeThumbnail(url: url) }
            let thumbMS = Date().timeIntervalSince(t2) * 1000

            let bytes = urls.compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int
            }.reduce(0, +)
            let line = String(format:
                "%d 张 %dx%d JPEG（共 %.1f MB）：建卡片 %.0f ms，平均 %.1f ms/张；认不出 %d 个\n"
                + "  其中判重 %.1f ms（%.1f%%）｜缩略图 %.1f ms（%.1f%%）\n",
                urls.count, w, h, Double(bytes) / 1024 / 1024,
                dt * 1000, dt * 1000 / Double(max(urls.count, 1)), built.unsupported,
                hashMS, hashMS / max(dt * 1000, 0.001) * 100,
                thumbMS, thumbMS / max(dt * 1000, 0.001) * 100)
            FileHandle.standardError.write(Data(line.utf8))
            exit(urls.count == 12 && built.items.count == 12 ? 0 : 1)
        }

        // 自检：重复文件判定（--dedupetest）
        // 用户 2026-10-29 第 4 轮第 3 条：内容一样的文件不许重复放进框里，
        // 而且**只能丢掉新来的那份，框里原来那个必须留着**。
        if CommandLine.arguments.contains("--dedupetest") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dedupe-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            func write(_ image: NSImage, to name: String) -> URL {
                let url = dir.appendingPathComponent(name)
                if let png = image.tiffRepresentation
                    .flatMap({ NSBitmapImageRep(data: $0) })?
                    .representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                }
                return url
            }

            let images = AppState.demoImages(2)
            let a = write(images[0], to: "page-1.png")              // 原件
            let b = write(images[0], to: "复制自 page-1.png")        // 同内容、不同名字
            let c = write(images[1], to: "page-2.png")              // 不同内容

            let app = AppState()
            let i1 = UploadItem(url: a)!
            let i2 = UploadItem(url: b)!
            let i3 = UploadItem(url: c)!

            var lines: [String] = []
            lines.append("指纹 a == b（同名内容同）：\(i1.fingerprint == i2.fingerprint)")
            lines.append("指纹 a != c（内容不同）：  \(i1.fingerprint != i3.fingerprint)")
            lines.append("加入 a       → \(app.addUpload(i1, for: .paper))")
            lines.append("加入 b(重复) → \(app.addUpload(i2, for: .paper))")
            lines.append("加入 c       → \(app.addUpload(i3, for: .paper))")
            let kept = app.items(for: .paper)
            lines.append("框里剩下 \(kept.count) 个（应为 2）")
            lines.append("原来那个还在：\(kept.first?.name == a.lastPathComponent)")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))

            let ok = i1.fingerprint == i2.fingerprint
                && i1.fingerprint != i3.fingerprint
                && kept.count == 2
                && kept.first?.name == a.lastPathComponent
            exit(ok ? 0 : 1)
        }

        // 自检：粘贴不支持的文件类型，**绝不许进预览框**（--pastetypetest）
        // 用户 2026-10-29 第 6 轮第 3 条报的致命 bug：
        // tiff / heic / gif 这些 NSImage 认得、但白名单里没有的格式，
        // 会先被 `UploadItem(url:)` 拒掉，然后又被 `NSImage(pasteboard:)` 解成图片塞进框里。
        // 这里用一块**私有剪贴板**复现，不动用户自己的剪贴板。
        if CommandLine.arguments.contains("--pastetypetest") {
            // 建卡片默认在后台线程做（见 AppState.acceptBatch）；自检要同步读到结果，
            // 这里把它拉回主线程。
            AppState.loadFilesOnMainThread = true
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("paste-type-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let base = AppState.demoImages(1)[0]
            let bitmap = NSBitmapImageRep(data: base.tiffRepresentation!)!

            func write(_ type: NSBitmapImageRep.FileType, _ name: String) -> URL {
                let url = dir.appendingPathComponent(name)
                if let data = bitmap.representation(using: type, properties: [:]) {
                    try? data.write(to: url)
                }
                return url
            }
            let tiff = write(.tiff, "卷子.tiff")     // 不支持：NSImage 认，白名单不认
            let png  = write(.png,  "卷子.png")      // 支持

            func run(_ urls: [URL]) -> (count: Int, names: [String], toast: String?) {
                let app = AppState()
                let pb = NSPasteboard(name: .init("exam-paste-test-\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects(urls.map { $0 as NSURL })
                app.paste(from: pb, into: .paper)
                return (app.items(for: .paper).count,
                        app.items(for: .paper).map(\.name),
                        app.toast)
            }

            let bad = run([tiff])
            let good = run([png])

            // 混合批次（用户 2026-10-29 第 7 轮第 2 条）：同一批里既有重复、又有类型不支持的，
            // 提示必须两件事都说到，而且框里只多进合法的那一个。
            let mixedApp = AppState()
            func feed(_ list: [URL]) {
                let pb = NSPasteboard(name: .init("exam-paste-test-\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects(list.map { $0 as NSURL })
                mixedApp.paste(from: pb, into: .paper)
            }
            feed([png])                 // 先放一张进去
            feed([png, tiff])           // 再来：同一张（重复）+ 一个 tiff（不支持）

            var lines: [String] = []
            lines.append("粘 .tiff → 框里 \(bad.count) 个（应为 0）  文件：\(bad.names)")
            lines.append("          提示：\(bad.toast ?? "无")")
            lines.append("粘 .png  → 框里 \(good.count) 个（应为 1）  文件：\(good.names)")
            lines.append("混合批次 → 框里 \(mixedApp.items(for: .paper).count) 个（应为 1）")
            lines.append("          提示：\(mixedApp.toast ?? "无")")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))

            let mixedToast = mixedApp.toast ?? ""
            let ok = bad.count == 0
                && good.count == 1
                && mixedApp.items(for: .paper).count == 1
                && mixedToast.contains("已经在框里")
                && mixedToast.contains("类型不支持")
            exit(ok ? 0 : 1)
        }


        // 自检：提示词拼装（--prompttest）——不用真跑一遍也能看 AI 收到什么
        if CommandLine.arguments.contains("--prompttest") {
            // 三种常态：单个 PDF、一整套图片、20 张手机照片
            let cases: [(String, [String])] = [
                ("1 个 PDF", ["2026届高三语文第3套.pdf"]),
                ("8 张图片", (1...8).map { "IMG_00\($0).jpg" }),
                ("20 张图片", (1...20).map { "page-\($0).png" }),
            ]
            var out = ""
            for (label, papers) in cases {
                let text = AppState.promptText(paperNames: papers)
                out += "===== \(label) =====\n\(text)\n"
                out += "首句: \(text.split(separator: "\n")[0])\n"
                out += "含结束标记: \(text.contains(AppState.endMarker))\n\n"
            }
            FileHandle.standardError.write(Data(out.utf8))
            exit(0)
        }

        // 自检：⌘J 开新对话（--keytest）
        //
        // 在根地址上按 ⌘J 是看不出效果的（本来就是空对话，URL 也没会话 id）。
        // 所以先发一句「你好」，等地址栏变成 /a/chat/s/<id>，再按 ⌘J ——
        // URL 变了才说明页面真的换了会话。
        if CommandLine.arguments.contains("--keytest") {
            let browser = BrowserController()
            DispatchQueue.global().async {
                func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }
                func js(_ code: String) -> String { (try? browser.evaluateSync(code)) ?? "<err>" }
                func waitURL(_ needle: String, _ limit: Double) -> Bool {
                    var t = 0.0
                    while t < limit {
                        if browser.currentURL.contains(needle) { return true }
                        wait(0.3); t += 0.3
                    }
                    return false
                }

                DispatchQueue.main.async { browser.loadDeepSeek(force: true) }
                var t = 0.0
                while !browser.isPageLoaded && t < 30 { wait(0.25); t += 0.25 }

                var r = 0.0
                while r < 15 {
                    if js(Scripts.probeComposer).contains("\"textarea\":true") { break }
                    wait(0.4); r += 0.4
                }
                print("就绪    \(browser.currentURL)")

                // 1. 发一句「你好」，把地址栏变成带会话 id 的样子
                print("填词    \(js(Scripts.fillText(textJSON: "\"你好\"")))")
                wait(0.3)
                print("发送    \(js(Scripts.sendNow))")

                guard waitURL("/a/chat/s/", 20) else {
                    print("❌ 20 秒内地址栏没出现会话 id：\(browser.currentURL)")
                    exit(2)
                }
                print("会话页  \(browser.currentURL)")
                let before = browser.currentURL

                // 2. 等这一轮答完（生成中页面可能忽略快捷键）
                wait(6.0)
                print("答完    输入框=\(js(Scripts.readText))")

                // 3. 注入 ⌘J
                DispatchQueue.main.sync { _ = browser.sendCommandKey("j", keyCode: 38) }
                wait(2.5)

                let after = browser.currentURL
                print("按前    \(before)")
                print("按后    \(after)")
                print(after != before ? "RESULT  = ✅ ⌘J 生效，换了会话"
                                       : "RESULT  = ❌ URL 没变，⌘J 没被页面接受")
                exit(0)
            }
        }

        // 脚本执行自检：--runpython /path/to/script.py
        if let idx = CommandLine.arguments.firstIndex(of: "--runpython"),
           idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            print("python = \(PythonRunner.executable?.path ?? "❌ 未找到")")
            print("size   = \(PythonRunner.sizeDescription)")
            let code = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            guard !code.isEmpty else {
                print("❌ 读不到脚本：\(path)")
                exit(2)
            }
            do {
                let r = try PythonRunner.run(script: code, timeout: 90)
                print("exit   = \(r.exitCode)  timeout=\(r.timedOut)")
                print("work   = \(r.workDir.path)")
                print("files  = \(r.producedFiles.map { $0.lastPathComponent })")
                print("--- output ---")
                print(r.output)
                if let doc = r.producedFiles.first(where: { $0.pathExtension == "docx" }) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: doc.path)
                    let size = (attrs?[.size] as? Int) ?? 0
                    print("--- docx \(size) bytes ---")
                }
                exit(r.ok ? 0 : 1)
            } catch {
                print("❌ \(error.localizedDescription)")
                exit(3)
            }
        }
    }

    var body: some Scene {
        WindowGroup("试卷识别") {
            ContentView().environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - 左上角关闭按钮 = 退出确认

/// 系统红灯（左上角关闭按钮）默认只关窗口，App 本身还留在后台。
/// 这里把它改成“退出 App”：窗口代理先拦住关闭（返回 false），
/// 发通知让 ContentView 在窗口绝对中心弹确认框；用户点“退出”才真正 terminate，
/// 点“取消”窗口原样保留。Cmd+Q 走系统退出，不经过这条路，不受影响。
/// 注意：代理只实现 windowShouldClose，其它窗口行为不受影响。
extension Notification.Name {
    static let examAppConfirmExit = Notification.Name("ExamAppConfirmExit")
}

final class ExitConfirmWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = ExitConfirmWindowDelegate()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .examAppConfirmExit, object: nil)
        return false
    }
}

/// 把窗口代理挂到主窗口上：NSViewRepresentable 的 view 一拿到 window 就设代理，
/// update 时再设一次，防止 SwiftUI 后续重建时代理被换掉。
struct WindowCloseAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = ExitConfirmWindowDelegate.shared
                // 标题栏只留红绿灯，不显示“试卷识别”几个字（和界面内大标题重复）。
                // 只隐藏标题栏文字，不改窗口本身的标题，Dock 菜单里的窗口名还在。
                window.titleVisibility = .hidden
                // 系统的分割线在这套「隐藏标题 + 透明标题栏」的窗口上压不住（只 hover 才出现），
                // 所以界面里自己画了一条常驻的（见 ContentView 顶部的 overlay）。
                // 这里把系统的关掉，免得上下一共两条线。
                window.titlebarSeparatorStyle = .none
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.delegate = ExitConfirmWindowDelegate.shared
                window.titleVisibility = .hidden
                window.titlebarSeparatorStyle = .none
            }
        }
    }
}

// MARK: - 手型光标

/// 可按的元素统一换成"手"光标。
/// 用 `onContinuousHover` + `NSCursor.set()` 而不是 push/pop：
/// push/pop 必须严格配对，视图在悬停中被移除（比如上传框选中后重绘）就会漏 pop，
/// 光标会永久卡成手型。`set()` 无栈，退出时再设回箭头即可。
struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// 给可按的元素加手型光标。**状态展示区不要加**。
    func handCursor() -> some View { modifier(HandCursor()) }
}

// MARK: - 旋转渐变描边

/// 激活状态元素的边框：一圈随时间旋转的渐变色。
/// 用 TimelineView 逐帧算角度，因为 AngularGradient 的 angle 不是可动画属性，
/// 用 withAnimation 推不动它。
struct RotatingGradientBorder: View {
    var radius: CGFloat = 16
    var lineWidth: CGFloat = 1.8
    var active: Bool = true
    var period: Double = 3.2

    private let colors: [Color] = [.brandAccent, .brandPurple, .brandPink, .brandAccent]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t.truncatingRemainder(dividingBy: period) / period) * 360)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: colors),
                                    center: .center, angle: angle),
                    lineWidth: lineWidth
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主界面

/// Word 卡在窗口坐标里的上沿。日志面板要**贴着它**铺 —— 靠量，不靠猜。
///
/// 以前 `LogPanel.scrimHeight` 是写死的 548（= 720 - 172，172 是当时估的 Word 卡高度）。
/// 实际 Word 卡上沿在 577，于是蒙版下沿（548）和 Word 卡之间永远空着 29pt，
/// 加上卡片自身的 4pt 边距，用户看到的就是一条 34pt 的空带 —— 这就是他两次说
/// 「日志框距离过远」的真正原因：不是卡片没贴边，是**蒙版高度估错了**。
/// 状态卡的说明文字换行时 Word 卡会上下浮动十几 pt，写死任何数字都会再错一次。
private struct WordCardTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let v = nextValue()
        if v > 0 { value = v }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showExitConfirm = false
    @State private var showLogoutConfirm = false
    // 主页面 hover：只做玻璃上的一层浅色提亮，不叠放大、提亮、brightness，
    // 退出/取消按钮那次闪黑闪白就是叠了那些才出的，这里不再重蹈覆辙。
    @State private var generateHover = false
    @State private var exitPrimaryHover = false
    @State private var logoutPrimaryHover = false
    @State private var clearPrimaryHover = false
    @State private var plainPrimaryHover = false
    @State private var loginHover = false
    @State private var loginBreathing = false
    @State private var recheckHover = false
    @State private var logoutHover = false
    /// ⌘V 监听器（等待粘贴态才接管）
    @State private var pasteMonitor: Any?
    /// 鼠标抬起监听器：点框外时退出等待粘贴
    @State private var clickMonitor: Any?
    /// Word 卡上沿（窗口坐标，由 `WordCardTopKey` 量出来）。0 = 还没量到。
    @State private var wordCardTop: CGFloat = 0

    /// 压暗层的高度 = **Word 卡的上沿 - 4**（量出来的，见 `WordCardTopKey`）。
    /// 蒙版下沿和 Word 卡之间只留 4pt，日志卡在蒙版里再上下各留 4 —— 三者叠起来
    /// 面板下边缘离 Word 卡只有 8pt，视觉上是「贴着」而不是「飘着」。
    /// 量不到时（首帧、或页面滚到别处导致数字离谱）退回老的 548。
    private var panelScrimHeight: CGFloat {
        guard wordCardTop > 300, wordCardTop < 700 else { return 548 }
        return wordCardTop - 4
    }

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 15) {
                    titleCard
                    UploadCard(slot: .paper,
                               title: "上传试卷",
                               subtitle: "整份试卷：多张图片可一次选完，或一个 PDF")
                    loginLine
                    generateButton
                    ProgressCard()
                    WordCard()
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: WordCardTopKey.self,
                                value: g.frame(in: .named("examRoot")).minY)
                        })
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                // 底部留白 **22 → 12**（用户 2026-10-29 第 5 轮第 2 条：整页会滚 2px）。
                // 实测卡片下边缘在 700.5pt，加 22 的底部留白 = 内容 722.5pt > 窗口 720pt，
                // 于是整页永远可滚 2.5px（就是「滚 2 像素」那个后遗症）。
                // 关键点：卡片位置只由「上留白 + 上方内容」决定，**改下留白不会移动卡片**，
                // 所以卡片到窗口底边的可见留白一点没变，只是把多出来的 10pt 让掉了。
                .padding(.bottom, 12)
            }
        }
        .frame(width: 620, height: 720)
        .coordinateSpace(name: "examRoot")
        .onPreferenceChange(WordCardTopKey.self) { wordCardTop = $0 }
        // 标题栏（红绿灯那条）下面的分割线 —— **自己画一条，常驻**（用户 2026-10-29 第 6 轮第 1 条）。
        //
        // 为什么不用系统的 `titlebarSeparatorStyle = .line`：那个属性在本窗口上不生效。
        // 窗口为了只留红绿灯，把 `titleVisibility` 设成了 `.hidden`，
        // 这种「标题栏透明、内容顶到窗口顶部」的形态下，系统只在滚动/鼠标悬停时才画那条线
        // （`.automatic` 的表现），`.line` 也压不住。与其跟系统猜，不如自己画一条 1px 的，
        // 位置正好在内容区最顶端 = 标题栏底边，颜色用系统的 `.separatorColor`，明暗自适应。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .background(WindowCloseAccessor())
        .onAppear {
            state.startPolling()
            // 兜底：界面出现时也直接给已存在的窗口挂上关闭代理，
            // 防止 background 的 NSView 在窗口挂接时序上没赶上。
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows {
                    // 内置网页窗口跳过：它有自己的大叉逻辑（只隐藏），
                    // 要是也挂上退出确认代理，点它的大叉就会弹主界面退出框。
                    if window is ParkableWindow { continue }
                    window.delegate = ExitConfirmWindowDelegate.shared
                }
            }
            // 开发用：--preview /path/to/file 启动即打开该文件的预览（验文档渲染最省事）
            if let idx = CommandLine.arguments.firstIndex(of: "--preview"),
               idx + 1 < CommandLine.arguments.count,
               let item = UploadItem(url: URL(fileURLWithPath: CommandLine.arguments[idx + 1])) {
                state.previewItem = item
                return
            }
            // 开发用：--uidemo / --uidemo2 只改界面状态，方便截图检查视觉
            if CommandLine.arguments.contains("--paneldemo") {
                // 同时摆出「日志面板」和「纯考卷确认框」，专门看位置
                state.applyPanelDemo()
            } else if CommandLine.arguments.contains("--scrolldemo") {
                PreviewScroller.debugLog = true
                state.applyScrollDemo()
            } else if CommandLine.arguments.contains("--uidemo") {
                state.applyUIDemo(step: 1)
            } else if CommandLine.arguments.contains("--uidemo2") {
                state.applyUIDemo(step: 2)
            } else if CommandLine.arguments.contains("--uidemo3") {
                state.applyUIDemo(step: 3)
            } else if CommandLine.arguments.contains("--uidemo4") {
                state.applyUIDemo(step: 4)
            } else if CommandLine.arguments.contains("--uidemo5") {
                state.applyUIDemo(step: 5)
            } else if CommandLine.arguments.contains("--uidemo6") {
                state.applyUIDemo(step: 6)
            } else if CommandLine.arguments.contains("--uidemo7") {
                state.applyUIDemo(step: 7)
            } else if CommandLine.arguments.contains("--uidemo8") {
                state.applyUIDemo(step: 8)
            } else if CommandLine.arguments.contains("--uidemo9") {
                state.applyUIDemo(step: 9)
            } else if CommandLine.arguments.contains("--logdemo") {
                state.applyLogDemo()
            } else if CommandLine.arguments.contains("--logintest") {
                state.runLoginSelfTest()
            } else if CommandLine.arguments.contains("--modeprobe") {
                state.runModeProbe()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .examAppConfirmExit)) { _ in
            showExitConfirm = true
        }
        .overlay {
            // 卡片放大预览：铺满整个窗口，压暗一点点，点任意处关闭。
            // 放在两个确认框之前，弹确认框时预览会被盖住。
            if let item = state.previewItem {
                PreviewPanel(item: item) { state.closePreview() }
            }
        }
        .overlay(alignment: .top) {
            // 运行日志：只压暗上半屏，底部 Word 卡（含「详情」按钮）留出来。
            // 面板绝不能盖住自己的开关 —— 盖住了用户就没法再点一次收起来。
            if state.showLog {
                LogPanel(scrimHeight: panelScrimHeight, onClose: { state.closeLog() })
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            }
        }
        .overlay {
            if showExitConfirm {
                exitConfirmOverlay
            }
        }
        .overlay {
            if showLogoutConfirm {
                logoutConfirmOverlay
            }
        }
        .overlay {
            if state.clearConfirmSlot != nil {
                clearConfirmOverlay
            }
        }
        .overlay(alignment: .top) {
            // 「要不要顺便生成纯考卷」。压暗层只铺上半屏 —— 下半屏的 Word 卡保持可见，
            // 用户一眼就知道含答案那份已经好了，纯考卷是额外加的。
            if let offer = state.plainOffer {
                plainOfferOverlay(offer)
                    .transition(.opacity)
            }        }
        .overlay(alignment: .top) {
            // 兜底：没指明哪个框的提示才放窗口顶部。上传框相关的提示都落在框中心（见 UploadCard）。
            if state.toastSlot == nil, let toast = state.toast {
                ToastBar(text: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.toast)
        .onAppear { installPasteMonitor() }
        .onDisappear {
            if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
            pasteMonitor = nil
            if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
            clickMonitor = nil
        }
    }

    /// ⌘V 监听 + 「点框外退出等待粘贴」。
    ///
    /// 粘贴：只有某个上传框处于「等待粘贴」状态时才接管，其余情况原样放行 ——
    /// 不能把别处的正常粘贴吃掉。Esc 顺手退出等待粘贴态（不吞事件，免得影响别的弹窗取消）。
    ///
    /// 取消：用户 2026-10-27 明确「框内再点不取消，只有点框外（必须在 app 范围内）才取消」，
    /// 后来补一句「左键连续点框内保持激活，右键也一样」。
    /// 这里不判断坐标 —— 判断坐标要处理 SwiftUI global 空间和 NSEvent 窗口空间的 y 轴翻转，
    /// 平台行为一变就会「点框内反而取消」。改成**票据制**：框内任何点击都会留一张票
    /// （`state.insideClickTicket`），mouseUp 之后异步看一眼 —— 有票作废票据、没票才取消。
    /// 用 local monitor 而不是 SwiftUI 手势：只有发给本 App 的事件才进来，
    /// 「点别的 app 不取消」这条天然满足。
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc：先关日志，再关预览，最后退等待粘贴（都不吞事件，免得影响别的弹窗取消）
            if event.keyCode == 53 {
                if state.showLog {
                    state.closeLog()
                } else if state.previewItem != nil {
                    state.closePreview()
                } else if state.pasteArmed != nil {
                    state.pasteArmed = nil
                    state.closePasteMenu()
                }
                return event
            }
            guard let slot = state.pasteArmed,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            state.pasteFromClipboard(into: slot)
            return nil
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
            guard state.pasteArmed != nil else { return event }
            // 顺序很关键：local monitor 在事件派发给视图**之前**跑，框自己的 onTapGesture 在**之后**跑。
            // 所以不能在派发前就判（那时票还没发），要推到下一轮 runloop —— 那时框内点击已经留过票了。
            DispatchQueue.main.async {
                if state.insideClickTicket {
                    state.insideClickTicket = false     // 这一下点在框内，留着
                } else if state.pasteArmed != nil {
                    state.pasteArmed = nil              // 点在框外，取消
                    state.closePasteMenu()              // 右键小菜单跟着一起收
                }
            }
            return event
        }
    }

    // MARK: 退出确认弹窗（窗口绝对中心）

    /// overlay 铺满整个 620×720 窗口，卡片在 ZStack 正中，
    /// 不是贴在某个角落，也不是系统 sheet。
    private var exitConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                Text("确认退出吗？")
                    .font(.system(size: 16, weight: .semibold))
                Text("退出后 App 将完全关闭。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 13) {
                    // 方案 1：主按钮保持系统玻璃 prominent，只在上面叠一层黑 0.06 hover 变深，
                    // 和取消按钮的系统 hover 逻辑统一（hover 变深、按下不弹起变浅是系统
                    // 自带的按下状态，这里只改 hover，不动按下）。不叠放大、不提亮、
                    // 不加手型光标。主窗口失焦时带颜色按钮变灰是系统行为，用户表示不介意，
                    // 不用自定义样式去绕它。
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("退出")
                            .font(.system(size: 13.5, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassProminentButtonStyle()
                    .tint(Color.brandRed)
                    .foregroundStyle(.white)
                    // 叠层本身不接点击：不加这一句，叠层盖在系统玻璃按钮上面，
                    // 即使填充透明也会挡住鼠标，退出按钮点不下去（2026-10-26 用户报）。
                    // 加在叠层内容上，不是加在整个按钮上，否则按钮自己也被禁点了。
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(exitPrimaryHover ? 0.06 : 0))
                        .allowsHitTesting(false))
                    .onHover { exitPrimaryHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: exitPrimaryHover)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        showExitConfirm = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 13.5, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .trialGlassCard(cornerRadius: 16, shadowOpacity: 0.18, shadowRadius: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 退出 DeepSeek 确认弹窗（和退出 App 确认框同一个做法）

    /// 以前是 NSAlert 系统弹窗，位置是屏幕居中，不是主界面绝对居中，
    /// 框和按钮也不是玻璃。现在改成和退出确认框一样的 overlay：
    /// 铺满整个 620×720 主界面，卡片在正中；整框玻璃，按钮也是系统玻璃，
    /// 按钮 hover 就靠系统玻璃本身，不再叠自定义放大、提亮、brightness。
    /// 文案原样保留 NSAlert 那两句，按钮位置和快捷键也和退出确认框一样：
    /// 主操作在左、取消在右，回车主操作、Esc 取消。
    private var logoutConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                Text("登出 DeepSeek 账号？")
                    .font(.system(size: 16, weight: .semibold))
                Text("会清掉本机保存的登录信息，然后重新打开登录页。之后需要重新扫码或输入账号密码登录。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // 按钮上下排、等宽对齐，中间留 10 空隙，和原来 NSAlert 的排布相似；
                // 主操作不再用红，用蓝，退出 App 那个确认框的红按钮不动。
                VStack(spacing: 10) {
                    Button {
                        showLogoutConfirm = false
                        state.logoutDeepSeek()
                    } label: {
                        Text("登出并重新登录")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassProminentButtonStyle()
                    .tint(Color.brandAccent)
                    .foregroundStyle(.white)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(logoutPrimaryHover ? 0.06 : 0))
                        .allowsHitTesting(false))
                    .onHover { logoutPrimaryHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: logoutPrimaryHover)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isRunning)
                    Button {
                        showLogoutConfirm = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 13.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            // 卡片定宽 360：小字一行约 24 个字，整段正好两行，不再被长句撑到满屏宽。
            .frame(width: 360)
            .trialGlassCard(cornerRadius: 16, shadowOpacity: 0.18, shadowRadius: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 清空确认弹窗（退出确认框的 85% 版）

    /// 用户 2026-10-29 第 4 轮第 2 条：框里 6 个及以上文件时才弹。
    /// 做法完全照搬退出确认框（整屏压暗 + 窗口正中 + 玻璃卡 + 主操作在左 / 取消在右 +
    /// 回车确认 / Esc 取消），只是**长宽都缩到 85% 左右** ——
    /// 所以字号、内边距、按钮间距、圆角、阴影半径都按 0.85 一起缩。
    private var clearConfirmOverlay: some View {
        let slot = state.clearConfirmSlot ?? .paper
        let count = state.items(for: slot).count
        return ZStack {
            Color.black.opacity(0.30)
            VStack(spacing: 12) {
                Text("清空这 \(count) 个文件？")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("清空后需要重新选择或粘贴。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 11) {
                    Button {
                        state.confirmClear()
                    } label: {
                        Text("清空")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 5)
                    }
                    .dialogGlassProminentButtonStyle()
                    .tint(Color.brandRed)
                    .foregroundStyle(.white)
                    // 叠层不接点击，否则会挡住系统玻璃按钮（和退出确认框同一个坑）
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(clearPrimaryHover ? 0.06 : 0))
                        .allowsHitTesting(false))
                    .onHover { clearPrimaryHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: clearPrimaryHover)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        state.cancelClear()
                    } label: {
                        Text("取消")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 5)
                    }
                    .dialogGlassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 3)
            }
            .padding(20)
            .trialGlassCard(cornerRadius: 14, shadowOpacity: 0.18, shadowRadius: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「要不要顺便生成纯考卷」。答案 ≥ 5 处时出现（见 `AppState.countAnswerHeads`）。
    ///
    /// 两个约束：
    /// 1. **只压暗上半屏**（548 = LogPanel 同一个值）。下半屏的 Word 卡保持可见，
    ///    用户一眼知道含答案那份已经好了，纯考卷是额外加的，不是替代。
    /// 2. 点压暗层 / Esc / 「不用了」三个都是放弃，行为一致 —— 不要出现「点外面关了但没记日志」。
    private func plainOfferOverlay(_ offer: PlainOffer) -> some View {
        // 蒙版必须顶到窗口上沿（和 LogPanel 一个位置）。这里以前写的是
        // `.frame(maxWidth: .infinity, maxHeight: .infinity)`，没给 alignment，
        // SwiftUI 默认按 center 摆 —— 548 的蒙版被垂直居中到窗口中间，
        // 于是它上沿离窗口顶空了 118pt，下沿一路压到 666pt，正好把底部 Word 卡
        // 从中间切开（「Word 转录」标题被压暗、下载按钮没压暗，中间一条硬边）。
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { state.declinePlainPaper() }

            VStack(spacing: 12) {
                Text("这份试卷里有 \(offer.answerCount) 处答案")
                    .font(.system(size: 13.5, weight: .semibold))

                Text("要不要顺便生成一份不带答案、也不带解析的纯考卷？\n大约还要 1–3 分钟。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 11) {
                    Button {
                        state.generatePlainPaper()
                    } label: {
                        Text("生成纯考卷")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 5)
                    }
                    .dialogGlassProminentButtonStyle()
                    .tint(Color.brandAccent)
                    .foregroundStyle(.white)
                    // 叠层不接点击，否则会挡住系统玻璃按钮（和清空确认框同一个坑）
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(plainPrimaryHover ? 0.06 : 0))
                        .allowsHitTesting(false))
                    .onHover { plainPrimaryHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: plainPrimaryHover)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        state.declinePlainPaper()
                    } label: {
                        Text("不用了")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 5)
                    }
                    .dialogGlassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 3)
            }
            .frame(width: 480)
            .padding(20)
            .trialGlassCard(cornerRadius: 14, shadowOpacity: 0.18, shadowRadius: 14)
        }
        // 蒙版高度跟日志面板共用同一个量出来的值（Word 卡上沿 - 4），卡片在蒙版里自动居中 ——
        // 不再写死 padding(.top, 186)，改文案也不会把卡片顶偏。
        .frame(height: panelScrimHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 标题

    /// 标题直接裸在背景上，不套圆角矩形 —— 之前那圈描边跟下面的卡片抢视觉重点。
    private var titleCard: some View {
        VStack(spacing: 9) {
            Text("试卷识别")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.brandAccent, .brandPurple],
                                   startPoint: .leading, endPoint: .trailing)
                )

            Text("把整份试卷的图片或 PDF 交给 AI，自动识别成一份可编辑的 Word 试卷。页数多时约需 3–10 分钟。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 登录

    private var loginLine: some View {
        // 两行合并为一行：启动时只有登录状态，检测出已登录后第二行再出现，
        // 原来会让窗口高度突然变大、看着突兀。现在整行高度固定为 30，
        // 第二行内容只在同一行里横向出现，窗口高度从启动到登录完成都不变。
        HStack(spacing: 8) {
            if state.loginSettled {
                Circle()
                    .fill(state.login.dotColor)
                    .frame(width: 8, height: 8)
                Text(state.login.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // 还没问出来之前只说"在检测"，不吓唬用户说没登录
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                Text("正在检测登录状态…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let mode = state.modeStatusText {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: state.modesChecking ? "arrow.triangle.2.circlepath" :
                          (state.modesReady ? "checkmark.circle.fill" : "exclamationmark.circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(state.modesReady ? Color.green : Color.secondary)
                    Text(mode)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // “重新检查”只在绿灯亮起 5 秒后仍未激活时出现，
                    // 5 秒内即使检测失败也不出现，见 AppState.modesRetryAllowed。
                    if !state.modesReady && !state.modesChecking && state.modesRetryAllowed {
                        Button {
                            state.retryDeepSeekModes()
                        } label: {
                            Text("重新检查")
                                .underline(recheckHover)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandAccent)
                        .handCursor()
                        .onHover { recheckHover = $0 }
                        .animation(.easeOut(duration: 0.15), value: recheckHover)
                    }
                }
            }

            Spacer(minLength: 6)

            // 未登录时，在登录按钮左边显示提示 + 纯文字箭头指向按钮。
            // 箭头就是文字“→”，不是带边框的图标，蓝、粗、明显；
            // 已登录、还在检测时都不显示，只有登录按钮出现时才出现。
            if state.loginSettled && !state.login.isLoggedIn {
                HStack(spacing: 4) {
                    Text("请登录后使用本软件")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.brandRed)
                        .lineLimit(1)
                    Text("→")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.brandAccent)
                }
            }

            // 登录行永远不显示倒计时：登录成功后 5 秒收窗口的倒计时，
            // 只在内置网页的徽标里显示（AppState.pushBadge），主界面这里不显示。
            // 未登录就直接显示登录按钮；退出后按钮要等探针确认已退出才出现，
            // 见 AppState.logoutDeepSeek / refreshLogin 的等待确认逻辑。
            if state.loginSettled && !state.login.isLoggedIn {
                Button { state.openDeepSeek() } label: {
                    Text("登录 DeepSeek")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .trialGlassCapsule(fallbackFill: Color.brandAccent.opacity(0.13))
                        .overlay(Capsule().fill(Color.brandAccent.opacity(loginHover ? 0.10 : 0)))
                        .foregroundStyle(Color.brandAccent)
                }
                .buttonStyle(.plain)
                .handCursor()
                .onHover { loginHover = $0 }
                .animation(.easeOut(duration: 0.15), value: loginHover)
                // 呼吸灯：外部光晕减弱，蓝光阴影在 0.10～0.28 透明度、4～8 半径之间 1.6 秒来回，
                // 内部玻璃和悬停效果、时长都不变；登录后按钮消失，呼吸也停。
                .shadow(color: Color.brandAccent.opacity(loginBreathing ? 0.28 : 0.10),
                        radius: loginBreathing ? 8 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        loginBreathing = true
                    }
                }
                .onDisappear { loginBreathing = false }
                .help("只在登录时会弹出窗口，登录成功后自动收起")
            }

            // 双绿灯（已登录 + 模式已激活）之后 0.5 秒出现：登出 DeepSeek。
            // 它接的是原来右下角「⋯」菜单里的「退出账号」，那个菜单连同底部状态行
            // 一起删掉了（用户 2026-10-27 要求），所以这是现在唯一的登出入口。
            // 点它只弹确认框，真正清登录态在确认之后。
            if state.logoutReady {
                Button { showLogoutConfirm = true } label: {
                    Text("登出 DeepSeek")
                        // 不加粗：用户 2026-10-27 明确要求
                        .font(.system(size: 12))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .trialGlassCapsule(fallbackFill: Color.brandAccent.opacity(0.13))
                        .overlay(Capsule().fill(Color.brandAccent.opacity(logoutHover ? 0.10 : 0)))
                        .foregroundStyle(Color.brandAccent)
                }
                .buttonStyle(.plain)
                .handCursor()
                .onHover { logoutHover = $0 }
                .animation(.easeOut(duration: 0.15), value: logoutHover)
                // 生成中禁点：退出登录会清掉整个网页数据，正在跑的识别直接废掉
                .disabled(state.isRunning)
                .help("登出 DeepSeek 账号，会清掉本机保存的登录信息")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        // 「登出 DeepSeek」按钮出现 / 消失用 0.5 秒淡入淡出。
        // 只绑 logoutReady，别给它挂别的动画。
        .animation(.easeOut(duration: 0.5), value: state.logoutReady)
    }

    // MARK: 主按钮

    private var generateButton: some View {
        Button {
            if state.isRunning { state.requestStop() } else { state.generate() }
        } label: {
            HStack(spacing: 7) {
                if state.isRunning {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                }
                Text(state.isRunning ? "中止" : "开始识别")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(state.canGenerate || state.isRunning
                             ? Color.white
                             : Color(nsColor: .secondaryLabelColor))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .trialGlassTinted(cornerRadius: 14,
                              tint: state.isRunning ? Color.brandRed : (state.canGenerate ? Color.brandAccent : Color.secondary),
                              fallback: buttonStyle,
                              shadowColor: shadowColor, shadowRadius: 16, shadowY: 7)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(generateHover ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { generateHover = $0 }
        .animation(.easeOut(duration: 0.15), value: generateHover)
        .disabled(!state.isRunning && !state.canGenerate)
    }

    private var shadowColor: Color {
        if state.isRunning { return Color.brandRed.opacity(0.34) }
        if state.canGenerate { return Color.brandAccent.opacity(0.32) }
        return .clear
    }

    private var buttonStyle: AnyShapeStyle {
        if state.isRunning {
            // 中止：珊瑚红 → 洋红，两个色差拉开一点，一眼看出是渐变
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.98, green: 0.40, blue: 0.36),
                         Color(red: 0.86, green: 0.18, blue: 0.56)],
                startPoint: .leading, endPoint: .trailing))
        }
        if state.canGenerate {
            return AnyShapeStyle(LinearGradient(
                colors: [.brandAccent, .brandPurple],
                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.16))
    }
}

// MARK: - 背景

struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    /// 紫族的三档，直接从 app 图标上采样来的：
    /// 图标是「右上 #A96BFA 浅紫 → 左下 #6D28D9 深紫」的斜向渐变。
    /// 主窗口沿用同一族色相，但把明度提上去、饱和度压下来 —— 整屏铺满高饱和紫会刺眼，
    /// 这里是背景不是主视觉，颜色只负责「氛围」，卡片和文字才是主角。
    private static let violetLight = Color(red: 0.663, green: 0.420, blue: 0.980)  // #A96BFA
    private static let violetDeep  = Color(red: 0.427, green: 0.157, blue: 0.851)  // #6D28D9

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        // 用户 2026-10-26 反馈：主背景不要玻璃，背景复杂就看不清。
        // 主背景保持实色 + 两团晕，玻璃只留给按钮和圆角框。
        ZStack {
            // 浅色下用带一点紫的冷白，而不是纯灰白，否则紫晕会显脏；
            // 深色下交回系统窗口底色，只叠晕，不然黑底上刷紫会发糊。
            if isDark {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color(red: 0.984, green: 0.976, blue: 0.996)   // #FBF9FE
            }
            // 右上浅、左下深，和图标同一个方向，切到 Dock 里看是一套的。
            // 透明度：浅色 0.07 / 0.06，深色 0.22 / 0.20 —— 深色底上同样的值会看不见。
            RadialGradient(colors: [Self.violetLight.opacity(isDark ? 0.22 : 0.07), .clear],
                           center: .topTrailing, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [Self.violetDeep.opacity(isDark ? 0.20 : 0.06), .clear],
                           center: .bottomLeading, startRadius: 20, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 上传卡片

/// 上传框（v0.18 的视觉，预览区从「恒定三等分」改成固定 6 栏网格）：
///
///     +---------------------------------------------------------------+
///       +----+ 上传试卷              Cmd+V 粘贴，点框外取消
///       | +  | 整份试卷：多张图片可一次选完，或一个 PDF，最多 48 张
///       +----+
///       [ ] [ ] [ ] [ ] [ ] [ ]   <- 一行 6 个
///       [ ] [ ] [ ] [ ] [ ] [ ]   <- 恒定两行高，多的框内滚动
///     +---------------------------------------------------------------+
///
/// 光标规矩（用户明确要求）：**只有加号是手型**，其余区域一律箭头；
/// 但其余区域按下会把整个框切到「等待粘贴」态 —— 细紫边 + 浅紫底 + 第一行中间出现提示。
/// 取消只有两条路：**点框外**（见 `installPasteMonitor`）或 Esc。
/// **框内再点不会取消**，这是用户特意要求的 —— 以前「再点一下取消」太容易误触。
///
/// 预览区规矩（用户 2026-10-29 第 3 轮第 4 条）：**固定 6 栏**；
/// **12 个以内恒 2 行**（不够的位置用虚框补齐，不随文件数变高变矮）；
/// **超过 12 个才加行**，最多 8 行 = 48 个，和图片上限对齐；
/// 但**可视高度永远是两行**（`previewHeight`），多出来的在框内滚动，
/// 自绘细滚动条浮在上面、不占布局宽度。
/// 「点击此处粘贴文件」那个标签已经删了（用户说多余），
/// 粘贴提示改由副标题临时改写承担，不占额外高度。
/// 读预览区的滚动偏移（自绘滚动条用）。
///
/// ⚠️ 为什么不用 `GeometryReader + .frame(in: .named(...))`，也不用 `.frame(in: .global)` 两个探针相减
/// （用户 2026-10-29 第 7 轮第 1 条报的 bug「滚动条不滚动」）：
/// 实测（离屏窗口里程序化滚到 90 再读）—— 两种 SwiftUI 侧的做法**都读不到变化**：
/// 命名空间解析不出来、`minY` 恒为 0；`.global` 那两个探针在滚动时也完全不重新求值。
/// 唯一可靠的是直接盯住 ScrollView 背后的 `NSScrollView`：
/// 给它的 `contentView` 打开 `postsBoundsChangedNotifications`，滚一下就读到新的 `bounds.origin.y`。
/// 同一套离屏测试里这个方案读到的正好是 90。
struct ScrollOffsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    /// 顺手把外层 `NSScrollView` 交给控制器 —— 拖滚动条、加行自动滚到底都要写偏移
    var scroller: PreviewScroller? = nil

    func makeNSView(context: Context) -> NSView {
        let v = ReaderView(onChange: onChange)
        v.scroller = scroller
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let v = nsView as? ReaderView
        v?.onChange = onChange
        v?.scroller = scroller
    }

    final class ReaderView: NSView {
        var onChange: (CGFloat) -> Void
        var scroller: PreviewScroller?
        private weak var clip: NSView?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 挂到窗口之后再找外层滚动视图，一次性接上
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let scroll = enclosingScrollView else { return }
            scroller?.scrollView = scroll
            let c = scroll.contentView
            clip = c
            c.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: c)
            boundsChanged()
        }

        @objc private func boundsChanged() {
            guard let clip else { return }
            onChange(clip.bounds.origin.y)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// 预览区的滚动控制器。
///
/// 为什么要有它：预览区背后的 `NSScrollView` 是 SwiftUI 自己造的，外面拿不到句柄，
/// 而「用鼠标拖自绘滚动条」「加了行以后自动滚到底」这两件事都得**写**偏移 ——
/// 只读（`ScrollOffsetReader`）不够。所以让 Reader 在 attach 的时候顺手把句柄登记进来。
///
/// 写偏移用 `contentView.animator().setBoundsOrigin(...)`：`NSClipView` 的滚动本质就是
/// bounds.origin 变化，改它等价于滚轮滚了一下，`postsBoundsChangedNotifications`
/// 照样会发通知，自绘滚动条就跟着走了。
final class PreviewScroller: ObservableObject {
    weak var scrollView: NSScrollView?
    static var debugLog = false

    /// 还能往下滚多少（内容高 - 可视高），永远 ≥ 0
    var maxOffset: CGFloat {
        guard let s = scrollView, let doc = s.documentView else { return 0 }
        return max(0, doc.frame.height - s.contentView.bounds.height)
    }

    /// 滚到内容坐标 y。`animated` 时用 0.5 秒缓动（用户 2026-10-29 第 9 轮第 2 条）。
    func scroll(to y: CGFloat, animated: Bool) {
        guard let s = scrollView else { return }
        let target = min(max(0, y), maxOffset)
        let point = NSPoint(x: 0, y: target)
        if PreviewScroller.debugLog {
            let docH = scrollView?.documentView?.frame.height ?? -1
            let visH = scrollView?.contentView.bounds.height ?? -1
            // 走 stderr：stdout 被重定向到文件时是全缓冲的，print 看不到
            let msg = "[scroll] want=\(y) target=\(target) max=\(maxOffset) doc=\(docH) vis=\(visH)\n"
            FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                ctx.allowsImplicitAnimation = true
                s.contentView.animator().setBoundsOrigin(point)
            } completionHandler: { [weak s] in
                guard let s else { return }
                s.reflectScrolledClipView(s.contentView)
            }
        } else {
            s.contentView.setBoundsOrigin(point)
            s.reflectScrolledClipView(s.contentView)
        }
    }

    func scrollToBottom(animated: Bool) { scroll(to: maxOffset, animated: animated) }

    /// 离底部还有多远。用来在布局比动画还慢的时候补一次。
    var distanceToBottom: CGFloat {
        guard let s = scrollView else { return 0 }
        return max(0, maxOffset - s.contentView.bounds.origin.y)
    }
}

struct UploadCard: View {
    @EnvironmentObject var state: AppState
    let slot: AppState.Slot
    let title: String
    let subtitle: String

    /// 加号 hover：自绘气泡，`.help()` 有约 1 秒系统延迟，达不到「几乎瞬间冒泡」
    @State private var plusHover = false
    @State private var cardHover = false
    /// 「清空」按钮 hover
    @State private var clearHover = false
    /// 预览区当前滚动偏移（自绘滚动条用）
    @State private var scrollOffset: CGFloat = 0
    /// 预览区滚动控制器（拖滚动条 / 加行自动滚到底要写偏移）
    @StateObject private var scroller = PreviewScroller()
    /// 拖动滚动条时按下的那个偏移；松手清空
    @State private var thumbDragStart: CGFloat?
    /// 上一次的行数，用来判断「是不是刚加了行」
    @State private var lastRowCount = 2
    /// 有文件正被拖到卡片上方（拖放高亮用）
    @State private var dropTargeted = false

    private var items: [UploadItem] { state.uploads[slot] ?? [] }
    private var armed: Bool { state.pasteArmed == slot }
    private var filled: Bool { !items.isEmpty }
    private var limits: (images: Int, docs: Int) { AppState.limits(for: slot) }

    private var limitText: String {
        "，图片最多 \(limits.images) 张，PDF 最多 \(limits.docs) 个"
    }

    private var borderColor: Color {
        // 拖放悬停时和「等待粘贴」用同一个强调色，用户一眼能看出「松手就收下」
        if dropTargeted { return Color.brandAccent.opacity(0.75) }
        if armed { return Color.brandAccent.opacity(0.75) }
        return Color.secondary.opacity(filled ? 0.22 : 0.28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            separator
            previewArea
        }
        // 左右内边距 15 → 12 → **10**（用户 2026-10-29 第 5、6 轮）：
        // 这就是他说的「总框内部那个看不见的总右边距」。改小之后预览区整体右移，
        // 自绘滚动条也跟着往右挪、离卡片边框更近，左边就腾出位置给格子了。
        .padding(.horizontal, 10)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard !state.isRunning else { return }
            // 点框内一律「激活」，不再「再点一次取消」（用户 2026-10-27）：
            // 取消只由「点框外」触发，见 installPasteMonitor 里的鼠标监听。
            state.armPaste(slot)
            state.closePasteMenu()      // 右键小菜单还开着的话，这一下把它收了
        }
        .trialGlassCard(cornerRadius: 16,
                        shadowOpacity: filled || armed ? 0.09 : 0.03,
                        shadowRadius: filled || armed ? 14 : 6)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(armed || dropTargeted ? Color.brandAccent.opacity(0.06)
                            : Color.brandAccent.opacity(cardHover ? 0.03 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            // 实线：虚线框在浅色背景上发飘，用户 2026-10-27 明确要求改实线
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: armed || dropTargeted ? 1.4 : 1)
                .allowsHitTesting(false)
        )
        // 拖放（用户 2026-10-29 第 7 轮第 2 条）：
        // 和粘贴/选文件走**完全同一套**规则 —— 类型白名单、数量上限、不许混放、内容判重，
        // 由 `state.acceptBatch` 统一处理，提示也是同一条汇总文案。
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !state.isRunning, !providers.isEmpty else { return false }
            AppState.resolveFileURLs(from: providers) { urls in
                state.acceptBatch(urls, for: slot)
            }
            return true
        }
        .overlay {
            // 右键：激活本框 + 在鼠标位置冒出「粘贴 / 取消」小菜单（用户 2026-10-27）。
            // 窗口失焦时的第一次左键也在这里接（否则会被 AppKit 吞掉），转成「激活」。
            // 平时左键完全穿透（见 RightClickCatcher）。
            RightClickCatcher(
                onRightClick: { point in
                    guard !state.isRunning else { return }
                    state.openPasteMenu(slot, at: point)
                },
                onFirstLeftClick: {
                    guard !state.isRunning else { return }
                    state.armPaste(slot)
                }
            )
        }
        .overlay {
            // 小菜单。位置夹在框内，免得贴边时半个菜单露到卡片外面去。
            if state.pasteMenuSlot == slot {
                GeometryReader { geo in
                    PasteBubble(
                        onPaste: {
                            // 留着激活态：和 ⌘V 粘贴完一样，框还是蓝的，可以接着粘下一张
                            state.keepPasteArmed(slot)
                            state.closePasteMenu()
                            state.pasteFromClipboard(into: slot)
                        },
                        onCancel: {
                            state.closePasteMenu()
                            state.pasteArmed = nil
                        }
                    )
                    .position(
                        x: min(max(state.pasteMenuPoint.x, 62), max(geo.size.width - 62, 62)),
                        y: min(max(state.pasteMenuPoint.y, 44), max(geo.size.height - 44, 44))
                    )
                }
            }
        }
        .overlay {
            // 提示落在**本框的正中心**（用户 2026-10-27：从窗口顶部降到对应框的中心）。
            // 只有 toastSlot 是自己的框才显示，两个框不会同时弹。
            if state.toastSlot == slot, let text = state.toast {
                ToastBar(text: text) { state.dismissToast() }
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .onHover { cardHover = $0 && !state.isRunning }
        .animation(.easeOut(duration: 0.15), value: cardHover)
        .animation(.easeOut(duration: 0.18), value: armed)
        .animation(.easeOut(duration: 0.18), value: filled)
        .animation(.easeOut(duration: 0.18), value: items.count)
    }

    // MARK: 标题行（加号在左，两行文案在右）

    /// 用户 2026-10-29 要求：加号不再是单独一行，改成 flex —— 左边一个加号方块，
    /// 右边两行文案。这样第一行不再被 46pt 高的加号撑着，纵向省下一整行。
    /// 加号方块的边长、加号与文案区的间距。
    /// 单独拎出来是因为「紫色提示要相对整框居中」要用到它俩算补偿量（见 headerRow）。
    private let plusSide: CGFloat = 46
    private let headerGap: CGFloat = 10

    private var headerRow: some View {
        HStack(alignment: .center, spacing: headerGap) {
            plusButton
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                    if filled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.green.opacity(0.9))
                    } else {
                        Text("＊必选")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.brandPink)
                    }
                    Spacer(minLength: 8)
                    // 右上角的「清空」：有文件、且没在跑的时候才出现。
                    // 跑的时候不给清，免得半路把附件从对话框里抽走。
                    // 卡片内边距 12→10 之后右边框往右移了 2pt，这里补 2pt 右边距，
                    // 让按钮看上去还停在原来的位置（用户 2026-10-29 第 6 轮第 2 条）。
                    if filled && !state.isRunning {
                        clearAllButton.padding(.trailing, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 等待粘贴时的紫色提示（用户 2026-10-29 第 4 轮第 1 条）：
                // **纵向**要跟「上传试卷」这行字居中，所以挂在**第一行**自己身上（不是整行）；
                // **横向**要相对整框居中，所以再往左补偿半个「加号 + 间距」的宽度 ——
                // 文案区左边被加号顶掉了 plusSide + headerGap，它的中心比卡片中心偏右
                // 半个这个宽度，补回来正好落在卡片正中。
                .overlay(alignment: .center) {
                    if armed {
                        // 用户 2026-10-29 第 9 轮：后半句「点框外取消」→「或拖入文件」，
                        // 让刚加的拖放功能在激活态里也看得见（字数一样，宽度不变）。
                        Text("按 ⌘V 或者右键粘贴，或拖入文件")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.brandAccent)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: -(plusSide + headerGap) / 2)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                // 第二行恒定是「支持哪些格式 + 数量上限」，激活粘贴时也不改写。
                // 窄窗口下按 0.9 缩一点，宁可小一号也不要截断成「…图片最多…」。
                Text(subtitle + limitText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 卡片右上角的「清空」（用户 2026-10-29 第 3 轮第 5 条，第 4 轮第 2 条改成玻璃形态）。
    /// 一次把框里的文件全清掉，省得一张张点右上角的叉。
    /// 位置：标题那一行的行末 —— 也就是卡片的右上角；卡片本身有 15pt 左右内边距，不会贴边。
    ///
    /// **闪烁修复**（用户报 hover 时闪）：以前有两个 hover 源（`.onHover` + `.handCursor()` 的
    /// `onContinuousHover`）在同一个按钮上打架，而且按钮宽度由内容撑开、hover 一重排就会
    /// 在「鼠标进 / 出」之间来回跳。现在：只留一个 hover 源、**宽高固定 58×22**（内容不再影响布局）、
    /// hover 效果全部用叠层 `opacity` 做，不再换填充色 —— 布局一动不动，就不会闪。
    private var clearAllButton: some View {
        Button {
            state.closePasteMenu()
            state.requestClear(for: slot)
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: "trash")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("清空")
                    .font(.system(size: 10.5, weight: .medium))
            }
            // 默认状态比原来的 .secondary 深一点（用户要求）
            .foregroundStyle(clearHover ? Color.brandRed : Color.primary.opacity(0.75))
            .frame(width: 58, height: 22)
            .background { clearButtonGlass }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // 只在真的变了才写，避免同一状态反复触发重绘
            guard clearHover != hovering else { return }
            clearHover = hovering
        }
        .help("清空这个框里的所有文件")
        .transition(.opacity)
    }

    /// 「清空」按钮的玻璃底：材质 + 内阴影 + 外阴影。
    ///
    /// SwiftUI 没有内阴影，这里用「一圈描边 + 模糊 + 裁进圆角」模拟：
    /// 描边往里晕开一点点，看起来就是边缘压暗的内阴影。
    /// 两层叠色（默认 / hover）都用 `opacity` 切换，不换颜色值，避免 hover 时重新合成闪烁。
    ///
    /// 用户 2026-10-29 第 5 轮第 4 条：阴影太明显 —— 浓度下调、扩散距离（blur / radius / 位移）
    /// 也一起收小，只留一层「薄薄的玻璃厚度」，不再有脏脏的一圈灰。
    private var clearButtonGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            // 默认压深一点
            shape.fill(Color.black.opacity(0.055))
                .opacity(clearHover ? 0 : 1)
            // hover：淡红底
            shape.fill(Color.brandRed.opacity(0.13))
                .opacity(clearHover ? 1 : 0)
            // 内阴影：描边细一点、模糊小一点、浓度降一半
            shape.strokeBorder(Color.black.opacity(clearHover ? 0.11 : 0.08), lineWidth: 1.0)
                .blur(radius: 0.7)
                .clipShape(shape)
            // 上沿高光（玻璃感）
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.70), Color.white.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
            // 外描边
            shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
        }
        .compositingGroup()
        // 外阴影：更淡、更近
        .shadow(color: .black.opacity(0.06), radius: 0.9, y: 0.5)
        .shadow(color: .black.opacity(0.03), radius: 0.3, y: 0.2)
    }

    /// 加号/文案 与 下方预览区 之间的分隔线（用户 2026-10-29 第 3 条）：
    /// 很细（1px）、很淡，只是把「说明区」和「文件区」轻轻划开，不抢视线。
    /// 上下各留 10pt，代替原来 VStack 的 11pt 间距。
    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.10))
            .frame(height: 1)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }

    // MARK: 预览区（恒定两行，一行 6 个）

    /// 用户 2026-10-29 第 3 轮第 4 条：
    /// - **12 个以内恒为 2 行**（不够的位置用虚框补齐），不随文件数变高变矮；
    /// - **超过 12 个才加行**：13 个 → 3 行，第 3 行 5 个虚框，依次类推；
    /// - **最多 8 行**（48 个），和 `limits` 里的图片上限对齐；
    /// - **3 行及以上才出现滚动条**，2 行正好铺满，不出现。
    private var previewArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(0..<slotCount, id: \.self) { index in
                    if index < items.count {
                        tile(items[index], index: index)
                    } else {
                        emptySlot
                    }
                }
            }
            .padding(.vertical, gridVPadding)
            .padding(.trailing, scrollBarGutter)
            .background(
                // 探针：直接读外层 NSScrollView 的 contentView.bounds.origin.y。
                // 阈值内不写，免得每帧都触发重绘。
                ScrollOffsetReader(onChange: { y in
                    let value = max(0, y)
                    if abs(scrollOffset - value) > 0.5 { scrollOffset = value }
                }, scroller: scroller)
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: previewHeight)
        // 自绘滚动条：**浮在上面**，不参与布局 —— 所以出现 3 行以上时，
        // 预览格子一个像素都不会被挤小（用户 2026-10-29 第 4 轮第 1 条）。
        .overlay(alignment: .topTrailing) { scrollIndicator }
        // 加了行就自动滚到底（用户 2026-10-29 第 9 轮第 2 条）：
        // 12 个以内恒 2 行、不滚动；一旦加过 12 个变成 3 行（以及 3→4、4→5…），
        // 用户刚放进去的文件就在最下面那一行，得让他看见 —— 0.5 秒滚过去，不要瞬移。
        //
        // 用 `.task(id:)` 而不是 `.onChange(of:)`：后者的单参数闭包在 macOS 14 已废弃，
        // 两参数版又要 14+，而本工程没显式设部署目标。`.task(id:)` 12+ 就能用，
        // 值一变就取消旧任务、起新的，正好。
        .task(id: rowCount) {
            let grew = rowCount > lastRowCount
            lastRowCount = rowCount
            guard grew else { return }
            // 200ms 不是拍脑袋：LazyVGrid 新增一行要等下一次布局，60ms 时量到的
            // 内容高度还是旧的（实测 doc=214 / 应为 264），滚到 40pt 就停了 ——
            // 上面那行露一半、新加的那行也露一半。200ms 时量到 doc=264，正好滚到 90。
            try? await Task.sleep(nanoseconds: 200_000_000)
            scroller.scrollToBottom(animated: true)
            // 兜底：机器慢 / 48 张要铺 8 行时，布局可能比 0.5s 的动画还慢。
            // 动画结束后如果还没到底，再补一次（只在这种时候才会多动一下）。
            try? await Task.sleep(nanoseconds: 560_000_000)
            if scroller.distanceToBottom > 1 { scroller.scrollToBottom(animated: true) }
        }
        // 空框时的一句提示：**在本行居中**（用户 2026-10-29 第一条）。
        // 它只是文案：不挂手势、也不吃点击（allowsHitTesting(false)），
        // 点它跟点框里其他空白处一样，落到框自己的 tap 上。
        // 有文件时 / 已经在等粘贴时 / 正在跑的时候都不显示。
        .overlay(alignment: .center) {
            if items.isEmpty && !armed && !state.isRunning {
                Text("点击此处可粘贴，或将文件拖入")
                    // 用户 2026-10-29 第 3 轮第 1 条：16 → 19，再淡一点。
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// 自绘滚动条（用户 2026-10-29 第 4 轮第 1 条：再细一点、再淡一点、离框右边再近一点）。
    ///
    /// 为什么不用系统滚动条：它的粗细/明暗跟系统设置走，改不了；更麻烦的是
    /// 一旦「始终显示滚动条」被打开，它**会吃掉布局宽度**，3 行以上时把预览格子挤小。
    /// 自绘版是 overlay，永远不占位置，格子尺寸从第一行到最后一行都一样。
    ///
    /// 可拖动（用户 2026-10-29 第 9 轮第 1 条）：以前整条挂了 `allowsHitTesting(false)`，
    /// 鼠标左键点上去直接穿过去落到卡片上，只有滚轮能动 —— 用户要的是「拖」。
    /// 可见条仍然只有 6pt 宽，但**命中区加宽到 14pt**（右边距那一条本来就是空的），
    /// 手不用瞄准。拖动时按「拇指位移 → 内容位移」等比换算，直接写 NSScrollView 的偏移。
    @ViewBuilder
    private var scrollIndicator: some View {
        if showsScrollbar {
            let visible = previewHeight
            let content = contentHeight
            let thumbH = max(20, visible * min(1, visible / max(content, 1)))
            let travel = max(visible - thumbH, 0)
            let maxOffset = max(content - visible, 1)
            let y = min(max(scrollOffset, 0), maxOffset) / maxOffset * travel

            // ⚠️ 必须 `.topTrailing`，不能用默认的 `.top`：ZStack 默认水平居中，
            // 14pt 的命中区里塞 6pt 的胶囊会被居中，右边缘从 1pt 变成 5pt —— 看起来
            // 就是「滚动条往左挪了一点」（用户 2026-10-29 第 10 轮一眼看出来）。
            ZStack(alignment: .topTrailing) {
                // 命中区：整条透明的，只有右边这一窄溜
                Color.clear
                    .frame(width: scrollHitWidth)
                    .contentShape(Rectangle())

                Capsule()
                    .fill(Color.secondary.opacity(thumbDragStart == nil ? 0.45 : 0.62))
                    .frame(width: scrollBarWidth, height: thumbH)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
            .frame(width: scrollHitWidth, height: visible)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = thumbDragStart ?? scrollOffset
                        if thumbDragStart == nil { thumbDragStart = start }
                        guard travel > 0.5 else { return }
                        // 拇指走 1pt，内容走 maxOffset/travel pt
                        let delta = value.translation.height * (maxOffset / travel)
                        scroller.scroll(to: start + delta, animated: false)
                    }
                    .onEnded { _ in thumbDragStart = nil }
            )
            .padding(.trailing, 1)
            .animation(.easeOut(duration: 0.15), value: thumbDragStart == nil)
        }
    }

    /// 滚动条命中区宽度：可见条 6pt，左右各多留 4pt，手不用瞄准。
    /// 不能更宽 —— 右边距只有 13pt，再宽就压到最后一列缩略图右上角那个「×」了。
    private let scrollHitWidth: CGFloat = 14

    /// 滚动条粗细 / 距框右边的留白。
    /// 用户 2026-10-29 第 6 轮第 2 条：3pt/0.22 → 5pt/0.34 → **6pt/0.45**。
    /// 格子右侧让位 11 → 13，于是格子与滚动条之间空出 13-1-6 = **6pt**；
    /// 卡片内边距缩到 10 之后，格子反而比上一版还宽 2pt（543）。
    private let scrollBarWidth: CGFloat = 6
    private let scrollBarGutter: CGFloat = 13

    /// 内容总高度：行数 × 格子高 + 行距 + 上下内边距。
    private var contentHeight: CGFloat {
        CGFloat(rowCount) * tileHeight + CGFloat(rowCount - 1) * 8 + gridVPadding * 2
    }

    /// 一共几行：12 个以内恒 2 行，超过才按需加，最多 8 行。
    private var rowCount: Int {
        min(8, max(2, (items.count + 5) / 6))
    }

    /// 一共几个格子 = 行数 × 6（空位用虚框补齐）。
    private var slotCount: Int { rowCount * 6 }

    /// 滚动条只在 3 行及以上出现 —— 2 行正好铺满可视高度，不该有滚动条。
    private var showsScrollbar: Bool { rowCount >= 3 }

    /// 固定 6 栏（用户 2026-10-29 第 2 轮第 4 条：不再按文件数动态改栏数）。
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
    }

    /// 每个格子的高度。可视高度恒为两行 + 行距 + 上下内边距。
    ///
    /// ⚠️ `gridVPadding` 必须算进高度（用户 2026-10-29 第 3 轮第 3 条报的 bug）：
    /// 之前只算了 `tileHeight * 2 + 8`，漏掉网格自己的上下各 1pt，
    /// 内容比可视区高出 2px —— 最底下那排虚线永远被切掉一点，还能滚 1–2 像素。
    private let tileHeight: CGFloat = 82
    private let gridVPadding: CGFloat = 1
    private var previewHeight: CGFloat { tileHeight * 2 + 8 + gridVPadding * 2 }

    /// 空位占位框：只有一圈淡虚线，没有底色 —— 看得见「这儿能放一张」，又不吵。
    /// 用户 2026-10-29 第 2 轮第 2 条：比第一版稍微加深一点（0.13 → 0.20）。
    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.20),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3.5]))
            .frame(height: tileHeight)
            .allowsHitTesting(false)
    }

    private var plusButton: some View {
        Button {
            // 加号也算「框内点击」，不退出等待粘贴（用户 2026-10-27：只有点框外才取消）。
            // 挑完文件回来框还是蓝的，再点框外一下就清了。
            state.keepPasteArmed(slot)
            state.chooseFile(for: slot)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.brandAccent.opacity(plusHover ? 1 : 0.8))
                .frame(width: plusSide, height: plusSide)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.brandAccent.opacity(plusHover ? 0.13 : 0.06))
                )
                .overlay(
                    // 实线（用户 2026-10-27：外框不要虚线）。加号跟着一起改实线，
                    // 免得框里一半实线一半虚线。
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.brandAccent.opacity(plusHover ? 0.6 : 0.32),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { plusHover = $0 }
        .animation(.easeOut(duration: 0.07), value: plusHover)
        .disabled(state.isRunning)
        .overlay(alignment: .topLeading) { uploadTooltip }
    }

    /// 自绘气泡：0.07 秒淡入，不挡鼠标。
    /// 加号现在在卡片左上角，往上浮会溢出卡片边界，所以改成**往下**冒，
    /// 正好压在预览区第一行上 —— tooltip 该有的样子（短暂、盖住内容、走开就消失）。
    /// 靠左对齐而不是居中：气泡比加号宽得多，居中会溢出卡片左边缘。
    @ViewBuilder
    private var uploadTooltip: some View {
        if plusHover && !state.isRunning {
            Text("点击此处上传文件")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .darkGray).opacity(0.95))
                )
                .fixedSize()
                .offset(y: 50)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: 预览格子（两行，一行最多 6 个）

    /// 格子只有 ~85pt 宽（一行 6 个），所以只放缩略图：图片铺满，PDF 显示图标 + 文件名。
    /// 文件名和大小放 `help` 里，鼠标停一下就能看全。
    /// 多于一个时左下角显示序号 —— 这是送给 AI 的顺序（不代表卷面顺序，AI 会按大标题自己排）。
    ///
    /// ⚠️ 尺寸由**底层的 Color** 撑住，图片只是盖在上面的 overlay（用户 2026-10-29 第 3 条）。
    /// 以前图片直接放在 ZStack 里：`.aspectRatio(contentMode: .fill)` 会把 **ZStack 自己**撑宽
    /// （横向图按高度填满后宽度超出格子），而 `.clipShape` 是在撑宽之后才裁的 ——
    /// 裁的边界已经是错的宽度，于是整块格子压到隔壁格子上、大幅度重叠。
    /// `Color` 是无限灵活的，永远只接受父级给的宽度，所以格子宽度恒等于列宽。
    private func tile(_ item: UploadItem, index: Int) -> some View {
        Color.secondary.opacity(0.07)
            .frame(maxWidth: .infinity, minHeight: tileHeight, maxHeight: tileHeight)
            .overlay { tileContent(item) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // 点格子 = 放大预览。放在叉按钮**之前**，让右上角那个叉优先吃到点击。
            .onTapGesture { state.openPreview(item) }
            .overlay(alignment: .bottomLeading) {
                if items.count > 1 {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                // 右上角的圆形大叉：移除这一张。
                // 白底深色叉（用户 2026-10-27 统一要求），描一圈淡边，浅色底上也能看清。
                Button {
                    state.removeUpload(item.id, for: slot)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.72))
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.16), lineWidth: 0.7))
                        .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("移除这个文件")
                .padding(4)
            }
        .help("\(item.name) · \(item.sizeText)")
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// 格子里的内容：有缩略图就铺满（溢出部分由外层 `clipShape` 裁掉），
    /// 没有缩略图（PDF / 取不到图）就显示图标 + 文件名。
    @ViewBuilder
    private func tileContent(_ item: UploadItem) -> some View {
        if let thumb = item.thumb {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            VStack(spacing: 5) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.brandAccent.opacity(0.85))
                Text(item.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - 右键层 + 「窗口没焦点时的第一次左键」

/// 让上传框能响应右键，同时**不影响左键**。
///
/// 为什么不用 SwiftUI：`onTapGesture` 只认左键；`.contextMenu` 会弹系统菜单；
/// `.gesture` 也接不到右键。AppKit 这边 `rightMouseDown` 是现成的，
/// 所以垫一个透明 NSView，在 `hitTest` 里**只在右键事件时返回自己**，左键一律返回 nil ——
/// 事件继续往下一层找，框的 tap、加号的按钮都照常工作。
///
/// 用户 2026-10-27 要求：框内右键 = 激活该框 + 在鼠标位置冒出「粘贴 / 取消」小菜单。
/// 左键连续点框内保持激活，右键也一样（不再是「右键取消」）。
///
/// **还顺手补了一个 macOS 的坑**（用户 2026-10-27 报）：窗口失去焦点、但仍然肉眼可见时，
/// 左键点框没反应，右键却正常。原因是 AppKit 的「第一次点击」规则 ——
/// 非 key 窗口上的左键只用来激活窗口，事件被吞掉，除非命中的视图
/// `acceptsFirstMouse` 返回 true。右键不受这条限制，所以只有左键坏。
/// 修法：窗口不是 key 时，这一层把左键也接过来（`hitTest` 返回自己），
/// `mouseDown` 里直接转成「激活粘贴框」。窗口变 key 之后照旧穿透，一切照常。
struct RightClickCatcher: NSViewRepresentable {
    /// 右键回调。参数是**框内坐标**（左上原点，y 向下），用来决定小菜单弹在哪
    let onRightClick: (CGPoint) -> Void
    /// 窗口没焦点时的第一次左键（本来会被 AppKit 吞掉）—— 转成「激活这个框」
    let onFirstLeftClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onRightClick = onRightClick
        v.onFirstLeftClick = onFirstLeftClick
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CatcherView else { return }
        v.onRightClick = onRightClick
        v.onFirstLeftClick = onFirstLeftClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        var onFirstLeftClick: (() -> Void)?

        /// 不返回 true 的话，窗口没焦点时这一层连事件都收不到
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 判断「当前这个事件是不是右键」—— NSApp.currentEvent 在命中测试期间就是它。
            // 不是右键就返回 nil，等于这一层不存在（左键穿透）。
            guard let type = NSApp.currentEvent?.type else { return nil }
            switch type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown:
                // 窗口不是 key：这一下左键本来会被 AppKit 吞掉（只拿去激活窗口），
                // 拦下来自己处理，让「点框 = 激活粘贴」在失焦状态下也成立。
                return window?.isKeyWindow == false ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            // NSView 默认坐标原点在左下，SwiftUI 的 overlay 是左上原点 —— 这里翻一下，
            // 否则小菜单会上下颠倒地弹出来。
            let p = convert(event.locationInWindow, from: nil)
            onRightClick?(CGPoint(x: p.x, y: bounds.height - p.y))
        }

        override func mouseDown(with event: NSEvent) {
            onFirstLeftClick?()
        }
    }
}

// MARK: - 右键小菜单

/// 右键弹出的两选一气泡（用户 2026-10-27）：圆角矩形、仿 glass、只有「粘贴 / 取消」。
/// 不用系统 `.contextMenu`：那个是系统样式的菜单，和这套玻璃卡片不搭，也没法定两个选项的样式。
struct PasteBubble: View {
    let onPaste: () -> Void
    let onCancel: () -> Void

    @State private var hover: Int?

    var body: some View {
        VStack(spacing: 0) {
            row(0, title: "粘贴", icon: "doc.on.clipboard", action: onPaste)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
                .padding(.horizontal, 8)
            row(1, title: "取消", icon: "xmark", action: onCancel)
        }
        .padding(5)
        .frame(width: 112)
        .trialGlassCard(cornerRadius: 12, shadowOpacity: 0.22, shadowRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
    }

    private func row(_ index: Int, title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover == index ? Color.brandAccent : Color.primary.opacity(0.86))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.brandAccent.opacity(hover == index ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hover = $0 ? index : (hover == index ? nil : hover) }
    }
}

// MARK: - 短提示条

/// 粘贴被拒、数量超限之类的一句话提示。
/// 位置：**触发它的那个上传框正中心**（用户 2026-10-27 要求，从窗口顶部降下来）。
/// 时长：渐显 0.18 秒 → 停 2.7 秒 → 渐隐 0.3 秒。
/// 存留期间点它一下也会走掉，渐隐速度和渐显一样（0.18 秒，见 `AppState.dismissToast`）。
struct ToastBar: View {
    let text: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color(nsColor: .darkGray).opacity(0.94))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        )
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
    }
}

// MARK: - 卡片放大预览

/// 点预览卡片 → 丝滑放大（0.62 → 1，弹簧收尾）。
/// - 图片：直接放大看内容（NSImage，最快最清晰）
/// - pdf / doc / docx：走 Quick Look（系统同款生成器，真实排版、可滚动翻页）
/// - 其余：退到信息卡（完整文件名、类型、大小、所在文件夹）
/// **点一下就关**（用户 2026-10-27 要求），背景压暗一点点只是为了聚焦。
/// 用户 2026-10-27 看过带尾巴的草图后说「先不带尾巴，和图片预览逻辑类似，宽度略大于图片」，
/// 所以这里是居中浮层：图片最宽 500，文档 540（略宽一点）。
struct PreviewPanel: View {
    let item: UploadItem
    let close: () -> Void

    /// 这几种交给 Quick Look 真渲染
    private static let quickLookTypes: Set<String> = ["pdf", "doc", "docx"]

    private var ext: String { item.url?.pathExtension.lowercased() ?? "" }

    private var typeText: String {
        switch item.url?.pathExtension.lowercased() {
        case .none: return "剪贴板图片"
        case "doc", "docx": return "Word 文档"
        case "pdf": return "PDF 文档"
        case "png", "jpg", "jpeg": return "图片"
        case .some(let ext): return "\(ext.uppercased()) 文件"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .transition(.opacity)
            VStack(spacing: 9) {
                if let thumb = item.thumb {
                    imagePanel(thumb)
                } else if let url = item.url, Self.quickLookTypes.contains(ext) {
                    documentPreview(url)
                } else {
                    docCard.overlay(alignment: .topTrailing) { closeButton.padding(8) }
                }
                Text("\(item.name) · \(item.sizeText)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.42)))
                Text("点右上角的 ✕ 或面板外面关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(18)
            .transition(.scale(scale: 0.62).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { close() }
    }

    /// 图片：**先按图片本身的比例算好显示尺寸**，再把叉压在图片内层。
    /// 之前用 `.frame(maxWidth: 500, maxHeight: 496)` —— 那个 frame 在图片比上限小的时候
    /// 仍会撑到上限那么大，叉就飘到图片外面去了（用户 2026-10-27 报的就是这个）。
    /// 现在宽高显式给定，容器和图片一样大，叉永远在画面里。
    private func imagePanel(_ thumb: NSImage) -> some View {
        let size = Self.displaySize(for: thumb)
        return Image(nsImage: thumb)
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) { closeButton.padding(10) }
            .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
    }

    private static func displaySize(for image: NSImage) -> CGSize {
        let maxW: CGFloat = 500
        let maxH: CGFloat = 496
        let w = max(image.size.width, 1)
        let h = max(image.size.height, 1)
        // 小图最多放大 3 倍，再大就糊了
        let scale = min(maxW / w, maxH / h, 3)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    /// 面板内层右上角的大叉（用户 2026-10-27 要求：放在内层、留一点边距）。
    /// 样式：**白底 + 深色叉**（用户 2026-10-27 统一要求，全 App 的叉都改成这样），
    /// 描一圈淡灰边，压在浅色图片上也看得见。
    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("关闭预览")
    }

    // MARK: 文档（Quick Look 真渲染）

    /// 宽 460 —— 用户 2026-10-27 说「改为现有的 85% 左右」（540 × 0.85 ≈ 459）。
    /// 上面留一条信息栏，正文交给 Quick Look / PDFKit。
    /// 注意：正文区域本身不接「点一下关闭」，否则翻页和滚动会被吃掉；
    /// 关面板靠右上角的 ✕、点信息栏、点面板外面或按 Esc。
    private func documentPreview(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brandAccent)
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(typeText) · \(item.sizeText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            // 右边多留 36：给内层右上角那个大叉让位，别让类型文字钻到叉底下
            .padding(.trailing, 36)
            .frame(height: 34)
            .contentShape(Rectangle())
            .onTapGesture { close() }

            Divider()

            // pdf 单独走 PDFKit：Quick Look 的 PDF 显示包是**独立进程**的远程视图（NSRemoteView），
            // 滚轮事件在那边不响应（用户 2026-10-27 反馈「pdf 滚轮无效，doc/docx 正常」）。
            // PDFKit 是进程内的 NSScrollView，滚轮、翻页、缩放都正常，清晰度也更好。
            if ext == "pdf" {
                PDFPreview(url: url)
                    .frame(width: 460, height: 480)
            } else {
                QuickLookPreview(url: url)
                    .frame(width: 460, height: 480)
            }
        }
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { closeButton.padding(8) }
        .shadow(color: .black.opacity(0.24), radius: 22, y: 8)
    }

    // MARK: 兜底信息卡

    private var docCard: some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.brandAccent)
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(typeText) · \(item.sizeText)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let dir = item.url?.deletingLastPathComponent().path {
                Text(dir)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
    }
}

// MARK: - Quick Look 渲染
/// 把系统的 Quick Look 预览视图塞进 SwiftUI。
/// 用的是 `QLPreviewView`（Finder 里按空格看到的就是它），
/// 所以 doc / docx / pdf 都由系统自带的 Office.qlgenerator、PDF.qlgenerator 出图，
/// **不需要装 Office**，也不会因为格式老旧而必然打不开。
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // 这个初始化器签名是可失败的，实际只在极端情况下返回 nil，
        // 真拿不到就没法预览，这里给个空 frame 兜住，别让整个界面炸掉。
        let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 460, height: 480),
                                 style: .normal) ?? QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        if CommandLine.arguments.contains("--qldebug") {
            QuickLookPreview.debugDump(view, path: url.lastPathComponent)
        }
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard (nsView.previewItem as? URL) != url else { return }
        nsView.previewItem = url as NSURL
        nsView.refreshPreviewItem()
    }

    /// 开发自检：`--qldebug` 启动时，3 秒后把预览视图的子视图类名打出来。
    /// 渲染成功会看到 WebView 一类的子视图；只有一个空容器就说明生成器没出图。
    /// 走 stderr（无缓冲），否则重定向到文件时 print 会被攒着不落盘。
    static func debugDump(_ view: NSView, path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            func emit(_ line: String) {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            func dump(_ v: NSView, _ depth: Int) {
                emit("QLDEBUG \(String(repeating: "  ", count: depth))\(type(of: v)) "
                     + "frame=\(NSStringFromRect(v.frame)) subviews=\(v.subviews.count)")
                for sub in v.subviews where depth < 6 { dump(sub, depth + 1) }
            }
            emit("QLDEBUG ===== \(path) =====")
            dump(view, 0)
        }
    }
}

// MARK: - PDF 渲染（PDFKit）

/// pdf 不用 Quick Look，改用 PDFKit 的 `PDFView`。
/// 原因（2026-10-27 查证）：Quick Look 给 pdf 分配的是 **独立进程**的 `NSRemoteView`，
/// 滚轮事件在那个远程进程里不响应 —— 用户实测「pdf 滚轮无效，doc/docx 正常」。
/// 而 doc/docx 是进程内的 `QLWeb2View` + WebKit，滚轮一直好使。
/// PDFKit 是进程内的 NSScrollView，滚轮/翻页/双指缩放都正常，页面清晰度也比 QL 的位图好。
struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true                     // 页面宽度自适应面板
        view.displayMode = .singlePageContinuous   // 连续滚动，多页往下翻
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = PDFDocument(url: url)
        if CommandLine.arguments.contains("--qldebug") {
            QuickLookPreview.debugDump(view, path: url.lastPathComponent)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
        view.autoScales = true
    }
}

// MARK: - 进度卡片

struct ProgressCard: View {
    @EnvironmentObject var state: AppState

    /// 空闲（没在跑、也没出结果/出错）时，状态框讲的是「还差哪一步」，
    /// 而不是最后一次操作。跑起来、成功、出错时才切到流程进度。
    private var showingIdle: Bool {
        !state.isRunning && state.progress.tone == .idle
    }

    private var title: String {
        showingIdle ? state.idleStatus.title : state.progress.title
    }

    private var detail: String {
        showingIdle ? state.idleStatus.detail : state.progress.detail
    }

    private var fraction: Double {
        showingIdle ? state.idleStatus.fraction : state.progress.fraction
    }

    private var spinning: Bool {
        showingIdle ? false : state.progress.running
    }

    private var isError: Bool {
        !showingIdle && state.progress.tone == .error
    }

    private var toneColor: Color {
        if showingIdle {
            return fraction >= 1 ? .green : Color.brandAccent.opacity(0.75)
        }
        switch state.progress.tone {
        case .ok: return .green
        case .error: return .brandRed
        case .idle: return state.progress.running ? Color.brandAccent : Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(toneColor).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isError ? Color.brandRed : Color.primary)
                Spacer(minLength: 6)
                if spinning {
                    Text("进行中")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ProgressBar(fraction: fraction, running: spinning)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trialGlassCard(cornerRadius: 16, shadowOpacity: 0.05, shadowRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: spinning)
                .opacity(spinning ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.3), value: fraction)
    }
}

struct ProgressBar: View {
    var fraction: Double
    var running: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                if fraction > 0.001 {
                    Capsule()
                        .fill(LinearGradient(colors: [.brandAccent, .brandPurple],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * min(1, fraction)))
                        .animation(.easeInOut(duration: 0.45), value: fraction)
                } else if running {
                    // 进度未知时跑一条来回扫的光带
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: 1.5) / 1.5
                        let w = geo.size.width * 0.34
                        let x = -w + (geo.size.width + w) * phase
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.clear, Color.brandAccent.opacity(0.9),
                                         Color.brandPurple.opacity(0.9), .clear],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: w)
                            .offset(x: x)
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

// MARK: - Word 试卷卡片

/// 一直占着位置，只是没生成时是「未激活」的样子 —— 用户知道成品会出现在这里。
struct WordCard: View {
    @EnvironmentObject var state: AppState

    /// 卡片和里面按钮的 hover，做法和上传卡、生成按钮一样：
    /// 只在玻璃上叠一层浅色提亮，不动玻璃、不放大、不提亮。
    @State private var cardHover = false
    @State private var downloadHover = false
    @State private var plainHover = false
    @State private var logHover = false

    /// 有纯考卷（生成中或已生成）时，卡片进入「两份」形态：标题变长、按钮拆成两个。
    /// 纯考卷失败时不算 —— 用户 19:45 定「失败就失败」，卡片老老实实退回单份，
    /// 不留一个永远点不动的按钮，失败原因只在「详情」里。
    private var twoWay: Bool {
        state.plainDocx.isReady || state.plainDocx.isBuilding
    }

    private var cardTitle: String {
        twoWay ? "Word 转录 · 含答案与纯考卷" : "Word 转录"
    }

    private var active: Bool { state.docx.isReady || state.plainDocx.isReady }

    private var message: String {
        if twoWay {
            if state.plainDocx.isBuilding {
                return state.docx.isReady
                    ? "含答案的那份已经好了，纯考卷还在生成，大约还要 1–3 分钟。"
                    : "纯考卷还在生成，大约还要 1–3 分钟。"
            }
            // 原版已经下载过了（下载完 docx 会回到 .idle），只剩纯考卷
            if !state.docx.isReady {
                return "纯考卷好了（\(sizeKB(state.plainDocx.url)) KB），点下面保存。含答案那份已经下载过了。"
            }
            let a = sizeKB(state.docx.url)
            let b = sizeKB(state.plainDocx.url)
            return "两份都好了：含答案 \(a) KB，纯考卷 \(b) KB。分别点下面的按钮保存。"
        }
        switch state.docx {
        case .idle:
            return "Word 文件还没有开始生成，等上面的进度走完再回到这里。"
        case .building:
            return "正在生成，稍等一下…"
        case .ready(let url):
            return "已经生成好了（\(sizeKB(url)) KB），点下面的按钮保存到电脑里。"
        case .failed(let why):
            // 失败只改这一行字，卡片其他部分一点不变（用户 2026-10-27：
            // 不要换按钮、不要弹面板、不要导 md/截图，日志一律看「详情」）。
            return "这次没成功：\(why)。点右上角「详情」可以看到这次运行的完整日志。"
        }
    }

    private func sizeKB(_ url: URL?) -> Int {
        guard let url = url else { return 0 }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) / 1024
    }

    private var buttonTitle: String {
        switch state.docx {
        case .idle: return "下载 Word 文件（尚未生成）"
        case .building: return "正在生成…"
        case .ready: return "下载 Word 文件"
        case .failed: return "下载 Word 文件（未生成）"
        }
    }

    private var plainButtonTitle: String {
        switch state.plainDocx {
        case .ready: return "下载纯考卷"
        case .building: return "正在生成纯考卷…"
        default: return "下载纯考卷"
        }
    }

    /// 下载按钮。两份形态下并排放两个，所以抽出来 —— 外观和原来那一个完全一样。
    private func pillButton(title: String, enabled: Bool,
                            hover: Binding<Bool>,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: enabled ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(enabled ? Color.white : Color(nsColor: .secondaryLabelColor))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .trialGlassTinted(cornerRadius: 10,
                              tint: enabled ? Color.brandAccent : Color.secondary,
                              fallback: enabled
                                ? AnyShapeStyle(LinearGradient(colors: [.brandAccent, .brandPurple],
                                                               startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.secondary.opacity(0.14)),
                              shadowColor: .clear, shadowRadius: 0, shadowY: 0)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hover.wrappedValue ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.wrappedValue)
        .disabled(!enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 15))
                    .foregroundStyle(active ? Color.brandAccent : Color.secondary)
                Text(cardTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if active {
                    // 纯绿字，不加药丸底（用户 2026-10-27：带边框看着像个能点的按钮）
                    Text("可下载")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
                // 运行日志入口。跑过一次之后才出现（没跑过没什么可看的）。
                // 放在标题行而不是按钮行：不挤「下载」的宽度，也不改变卡片高度。
                if !state.progressLines.isEmpty {
                    Button { state.toggleLog() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 9, weight: .semibold))
                            Text(state.showLog ? "收起" : "详情")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.brandAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .trialGlassCapsule(fallbackFill: Color.brandAccent.opacity(logHover ? 0.16 : 0.09))
                        .overlay(Capsule().fill(Color.brandAccent.opacity(logHover ? 0.10 : 0)))
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .onHover { logHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: logHover)
                    .help("看这次运行的详细日志")
                }
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(state.docx.isReady ? Color.secondary : Color.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if twoWay {
                // 两份形态：左「含答案」，右「纯考卷」。下载完的那份变灰但**不消失**，
                // 用户一眼能看出哪份已经存过了（19:45 定：两份都要下完才解锁新任务）。
                HStack(spacing: 10) {
                    pillButton(title: state.docx.isReady ? "下载含答案试卷" : "含答案已下载",
                               enabled: state.docx.isReady,
                               hover: $downloadHover) { state.downloadDocx() }
                    pillButton(title: plainButtonTitle,
                               enabled: state.plainDocx.isReady,
                               hover: $plainHover) { state.downloadPlainDocx() }
                }
            } else {
                // 单份形态：成功失败都是这一个按钮（用户 2026-10-27：失败时不要换按钮、
                // 不要弹面板、不要导 md/截图）。没生成好就是禁用态，日志去「详情」看。
                HStack(spacing: 10) {
                    pillButton(title: buttonTitle,
                               enabled: state.docx.isReady,
                               hover: $downloadHover) { state.downloadDocx() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trialGlassCard(cornerRadius: 16, shadowOpacity: active ? 0.08 : 0.02, shadowRadius: active ? 12 : 5)
        // 卡片 hover 叠层盖在整个卡片上面，包括里面的下载/导出/详情按钮。
        // 不加 allowsHitTesting(false)，即使填充透明也会挡住鼠标 —— 讲义 app v0.27 修过一模一样的
        // bug（退出按钮点不动），克隆时这行漏了，下载按钮就点不动。加在叠层内容上、不是整个卡片上，
        // 否则卡片里的按钮全被禁点；hover 还是靠卡片自己的 onHover，不受影响。
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.brandAccent.opacity(cardHover ? 0.04 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(active ? 0 : 0.28), lineWidth: 1.2)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: active)
                .opacity(active ? 1 : 0)
        )
        .onHover { cardHover = $0 && active }
        .animation(.easeOut(duration: 0.15), value: cardHover)
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

// MARK: - 运行日志面板

/// 「详情」按钮打开的那块。成功跑完也能看 —— 之前 `progressLines` 只在失败诊断的
/// md 里出现，成功一次就什么都看不到，想确认「提示词回读一致」也没地方确认。
///
/// 两个约束（用户 2026-10-27 定）：
/// 1. **不许盖住自己的开关**。所以压暗层只铺上半屏（`scrimHeight`），底部给 Word 卡
///    留出一条不遮不挡的带子，「详情」按钮永远点得到。
/// 2. 显示/隐藏跟预览卡片一个节奏：`withAnimation(.easeOut(0.18))` + opacity 过渡。
///    窗口本来就是固定 620×720，所以这里直接写死尺寸，不追求自适应。
struct LogPanel: View {
    @EnvironmentObject var state: AppState
    /// 压暗层高度，由 `ContentView.panelScrimHeight` 量出来（= Word 卡上沿 - 4）
    var scrimHeight: CGFloat = 548
    let onClose: () -> Void

    /// 复制后 1.6 秒内按钮显示「已复制」，给个明确的反馈
    @State private var copied = false

    private var lines: [String] { state.progressLines }
    private var scriptOutput: String { state.scriptOutput }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.14)
                .frame(maxWidth: .infinity)
                .frame(height: scrimHeight)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            // 卡片贴着蒙版铺满：上下各留 4px。
            card.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logList
        }
        .frame(width: 566, height: max(120, scrimHeight - 8))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brandAccent)
            Text("运行日志")
                .font(.system(size: 13, weight: .semibold))
            Text("\(lines.count) 行")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()

            // 一键拷全部。每行是独立 Text，SwiftUI 的跨行拖选会被打断，
            // 只能一行一行选 —— 用户要截图两次以上才拿得全，所以给个按钮。
            Button(action: copyAll) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                    Text(copied ? "已复制" : "复制全部")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Color.black.opacity(0.72))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(lines.isEmpty && scriptOutput.isEmpty)
            .opacity(lines.isEmpty && scriptOutput.isEmpty ? 0.45 : 1)
            .help("把整份日志拷到剪贴板（含脚本输出）")

            // 叉按钮统一白底黑字（用户 2026-10-27 定的规矩，系统级的除外）
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 把面板里看到的东西原样拷进剪贴板：日志行 + 分隔线 + 脚本输出。
    /// 顺序和界面一致，贴到别处不用再拼。
    private func copyAll() {
        var parts = lines
        if !scriptOutput.isEmpty {
            if !parts.isEmpty { parts.append("") }
            parts.append("—— 脚本输出 ——")
            parts.append(scriptOutput)
        }
        guard !parts.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(parts.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty && scriptOutput.isEmpty {
                        Text("这次还没有日志。跑一次生成就会有了。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tint(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if !scriptOutput.isEmpty {
                        Divider().padding(.vertical, 6)
                        Text("—— 脚本输出 ——")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(scriptOutput)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 滚到底用的锚点
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            // 跟着日志增长自动滚到底。用 onReceive 而不是 onChange：
            // onChange 的单参数写法在 macOS 14 已废弃，而本工程部署目标是 13.0。
            .onReceive(state.$progressLines) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    /// 出错的标红，警告标黄，其余保持正文色 —— 扫一眼就知道哪行有问题
    private func tint(for line: String) -> Color {
        if line.hasPrefix("✗") { return Color.brandRed }
        if line.contains("⚠️") || line.contains("还没出现") { return Color.orange }
        return Color.primary.opacity(0.85)
    }
}
