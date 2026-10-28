import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct LoginStatus {
    enum Kind {
        case unknown, loggedIn, loggedOut, noSafari, noWindow, noPage, wrongPage, noPermission, jsDisabled
    }

    var kind: Kind = .unknown
    var detail: String = ""

    var isLoggedIn: Bool { kind == .loggedIn }

    var needsJSHelp: Bool { kind == .jsDisabled }

    var dotColor: Color {
        switch kind {
        case .loggedIn: return .green
        case .loggedOut, .wrongPage: return .orange
        case .noPermission, .jsDisabled: return .red
        default: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var label: String {
        switch kind {
        case .loggedIn: return "已登录 DeepSeek"
        case .loggedOut: return "还没登录 DeepSeek"
        case .noSafari: return "Safari 未运行"
        case .noWindow: return "Safari 没有打开窗口"
        case .wrongPage: return "当前标签页不是 DeepSeek"
        case .noPermission: return "缺少控制 Safari 的权限"
        case .jsDisabled: return "Safari 未开启「允许来自 Apple 事件的 JavaScript」"
        case .noPage: return "正在连接 DeepSeek…"
        case .unknown: return "正在检查登录状态…"
        }
    }
}

/// 给不懂编程的人看的进度，只保留「在干什么 / 到哪一步了 / 成没成」
struct ProgressInfo: Equatable {
    enum Tone { case idle, ok, error }

    var title: String = "等待上传试卷"
    var detail: String = "把整份试卷放进来：多张图片一次选完，或者一个 PDF；两类不能混放。"
    /// 0 表示进度不确定（用滚动条动画），0~1 之间才是确定的百分比
    var fraction: Double = 0
    var running: Bool = false
    var tone: Tone = .idle
}

/// 空闲时状态框显示什么 —— 按「题目 / 作文 / 登录」的组合给书面文案
struct IdleStatus {
    var title: String
    var detail: String
    /// 0~1，用来画"准备到哪一步了"的进度条
    var fraction: Double
}

/// 批改稿的状态机 —— 界面那张「Word 批改稿」卡片直接照着它渲染
enum DocxState: Equatable {
    case idle                 // 还没开始，卡片显示为未激活的占位
    case building             // 正在生成
    case ready(URL)           // 好了，可以下载
    case failed(String)

    var isReady: Bool { if case .ready = self { return true }; return false }
    var isBuilding: Bool { if case .building = self { return true }; return false }
    var url: URL? { if case .ready(let u) = self { return u }; return nil }
}

/// 上传框里的一张预览卡片（v0.18 界面改版引入）。
/// 一个框里可以放「若干个文档」或「若干张图片」，但不能混放，
/// 数量上限见 `AppState.limits(for:)`。
struct UploadItem: Identifiable, Equatable {
    enum Kind { case document, image }

    /// 只收这几种。pdf 是文档、png/jpg 是图片，其余一律拒绝。
    /// 试卷识别的输入只有「一堆图片」或「一个 PDF」，doc/docx 不在其列 ——
    /// 已经有文字的 Word 不需要 OCR。
    static let allowedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    let id = UUID()
    /// 文档 / 磁盘上的图片都有 URL；从剪贴板来的内存图片没有，落盘留到接流水线那一步做
    var url: URL?
    var kind: Kind
    var name: String
    var sizeKB: Int
    /// 图片的缩略图；文档为 nil，卡片里画一个 SF Symbol
    var thumb: NSImage?
    /// 是不是「从剪贴板粘进来的图片」。命名序号只数这个，上传的文件不算
    /// （上传的文件自带文件名，见 `AppState.nextPasteName`）。
    var isPaste = false

    /// 判重指纹（用户 2026-10-29 第 4 轮第 3 条）。
    /// **按文件内容算，不按文件名** —— 同一个文件复制一份、改个名字再贴进来，也算重复。
    /// 反过来，两个不同的文件即使同名也不算重复。
    let fingerprint: String

    static func == (a: UploadItem, b: UploadItem) -> Bool { a.id == b.id }

    /// 内容指纹：**字节数 + 头 128KB + 尾 128KB** 的 SHA-256。
    ///
    /// 原来是「整份文件读进内存再哈希」（用户 2026-10-29 第 8 轮报「10 个文件以上很卡」的原因之一）。
    /// 现在只读头尾各 128KB：几百 KB 的读盘 + 一次短哈希，单文件从几十毫秒降到 1ms 量级；
    /// 判重效果几乎不变 —— 同尺寸又同头同尾的两张试卷图，实际不会出现。
    /// 小于 256KB 的文件头尾会重叠，等于整份内容，反而更准。
    static func fingerprint(ofFileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 128 * 1024
        var sample = Data()
        try? fh.seek(toOffset: 0)
        sample.append((try? fh.read(upToCount: Int(chunk))) ?? Data())
        if size > chunk * 2 {
            try? fh.seek(toOffset: size - chunk)
            sample.append((try? fh.read(upToCount: Int(chunk))) ?? Data())
        }
        var hasher = SHA256()
        hasher.update(data: sample)
        hasher.update(data: Data("\(size)".utf8))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(hex)"
    }

    /// 内存里的 `Data`（剪贴板图片编码出来的 PNG）用同一套算法算指纹：
    /// **字节数 + 头 128KB + 尾 128KB**，和 `fingerprint(ofFileAt:)` 的结果可以互相比较。
    static func fingerprint(of data: Data) -> String {
        let chunk = 128 * 1024
        var sample = Data()
        sample.append(data.prefix(chunk))
        if data.count > chunk * 2 { sample.append(data.suffix(chunk)) }
        var hasher = SHA256()
        hasher.update(data: sample)
        hasher.update(data: Data("\(data.count)".utf8))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(data.count)-\(hex)"
    }

    /// 小图缩略图的最大边长（像素）。
    /// 卡片格子 84pt、Retina 2x 也就 168px，360 已经够；再大纯浪费内存和解码时间。
    static let thumbnailMaxPixel = 360

    /// 剪贴板图片落盘成 PNG 前允许的最大边长（像素）。
    /// 手机截图、网页长图动辄 3000px 往上，按原尺寸编码 PNG 又慢又大（10MB+），
    /// 而这张图只是拿去 OCR 认字 —— 2048 的长边完全够，编码时间能砍掉一大半。
    static let pasteMaxPixel = 2048

    /// NSImage → CGImage（拿不到就返回 nil，调用方退回老路子）
    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 等比缩到长边不超过 `maxPixel`；本来就够小就原样返回。
    static func downscaled(_ cg: CGImage, maxPixel: Int) -> CGImage {
        let longSide = max(cg.width, cg.height)
        guard longSide > maxPixel, longSide > 0 else { return cg }
        let scale = CGFloat(maxPixel) / CGFloat(longSide)
        let w = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    /// 生成**降采样**缩略图（关键优化，用户 2026-10-29 第 8 轮）。
    ///
    /// 以前是 `NSImage(contentsOf:)` 直接拿整张原图当缩略图：
    /// 一张 4000×3000 的照片解出来约 48MB 位图，而卡片只画 84pt —— 10 张就是近 500MB，
    /// 全在主线程解，所以「一粘 10 个文件就卡住」。
    /// `CGImageSourceCreateThumbnailAtIndex` 只解出 360px 的小图，单张从几十毫秒降到 1–3ms。
    static func makeThumbnail(url: URL, maxPixel: Int = thumbnailMaxPixel) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: src, maxPixel: maxPixel)
    }

    static func makeThumbnail(data: Data, maxPixel: Int = thumbnailMaxPixel) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: src, maxPixel: maxPixel)
    }

    private static func thumbnail(from src: CGImageSource, maxPixel: Int) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 跟着 EXIF 方向转正
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    var sizeText: String {
        sizeKB >= 1024 ? String(format: "%.1f MB", Double(sizeKB) / 1024) : "\(sizeKB) KB"
    }

    /// 从磁盘文件建卡片；扩展名不在白名单里就返回 nil
    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else { return nil }
        self.url = url
        self.name = url.lastPathComponent
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        self.sizeKB = max(bytes / 1024, 1)
        // 读不出内容就当没有指纹（空串），判重时不会误判成重复
        self.fingerprint = Self.fingerprint(ofFileAt: url) ?? ""
        if Self.imageExtensions.contains(ext) {
            self.kind = .image
            self.thumb = Self.makeThumbnail(url: url)     // 降采样，不再拿原图
        } else {
            self.kind = .document
            self.thumb = nil
        }
    }

    /// 从剪贴板里的内存图片建卡片（截图、网页里右键复制的图）。
    /// **会落成一张真 PNG 临时文件**（用户 2026-10-27 要求）—— 流水线只认磁盘文件，
    /// 网页端也拿不到"内存里的图片"，很多网页版 App 都是这么做的。
    ///
    /// 名字由调用方给（`AppState.nextPasteName`），**不再从磁盘文件名倒推**：
    /// 以前是「临时目录里没被占用的最小序号」，而临时目录里的旧图 App 退出也不清，
    /// 序号就一路涨到 8、9、10，关掉重开也回不到 1（用户 2026-10-27 报的问题）。
    init(image: NSImage, name: String) {
        self.kind = .image
        self.isPaste = true

        // ① 先把超长边缩到 2048 再编码 PNG。
        //    原来直接拿原图 `tiffRepresentation → PNG`，一张 3000×4000 的截图要编码十几 MB，
        //    这一步就是「粘一张大图要等一两秒」的元凶。
        let png: Data? = Self.cgImage(from: image)
            .map { Self.downscaled($0, maxPixel: Self.pasteMaxPixel) }
            .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }

        // ② 缩略图从这张小 PNG 降采样到 360，不再把原图直接塞进卡片（原图一张几十 MB 位图）
        self.thumb = png.flatMap { Self.makeThumbnail(data: $0) } ?? image
        self.sizeKB = max((png?.count ?? 0) / 1024, 1)
        // 剪贴板图片按落盘后的 PNG 内容算指纹：
        // 同一张图连着粘两次，序号不同、文件名不同，但内容一模一样 —— 必须判成重复。
        self.fingerprint = png.map { UploadItem.fingerprint(of: $0) } ?? ""

        let url = UploadItem.pasteDirectory.appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: UploadItem.pasteDirectory,
                                                 withIntermediateDirectories: true)
        if let png = png, (try? png.write(to: url)) != nil {
            self.url = url
            self.name = url.lastPathComponent
        } else {
            // 落盘失败也别让卡片消失，至少还能看、还能移除
            self.url = nil
            self.name = "\(name) \(Int(image.size.width))×\(Int(image.size.height))"
        }
    }

    /// 剪贴板图片的落盘目录。用系统临时目录：App 退出后由系统回收，
    /// 卡片被移除或生成成功时我们也会主动删。
    static var pasteDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("试卷识别-粘贴", isDirectory: true)
    }
}

final class AppState: ObservableObject {
    /// 只有一个上传框：整份试卷（N 张图片，或者 1 个 PDF）。
    /// 原来的「题目 / 作文」两个槽位在这里合并 —— 试卷识别只有一份输入。
    enum Slot: Hashable { case paper }

    /// 上传框里的内容。界面和流水线都按它走。
    @Published var uploads: [Slot: [UploadItem]] = [:]

    /// 当前处于「等待粘贴」状态的框，同时只有一个：点另一个框会把它取消。
    @Published var pasteArmed: Slot?

    /// 框内点击的「票据」：框内任何点击（左键 tap、加号、右键）都会置 true。
    /// 全局鼠标监听在 mouseUp 之后看一眼：**有票就不取消，没票就取消**。
    ///
    /// 用户 2026-10-27 定的规矩：**框内再点不取消，只有点框外才取消**。
    /// 一开始用的是时间戳（框内点击刷新时间），但右键可以按住不放 ——
    /// 按住的时长会把时间戳拖过阈值，长按右键就被误判成「点在外面」。
    /// 换成一次性票据，跟按键时长完全无关。
    var insideClickTicket = false

    /// 框内被点击：激活等待粘贴，并留一张票（让框外监听知道这一下不算「点在外面」）
    func armPaste(_ slot: Slot) {
        pasteArmed = slot
        insideClickTicket = true
    }

    /// 框内某个控件（加号、缩略图）被点了：本来就在等粘贴的话，别退出
    func keepPasteArmed(_ slot: Slot) {
        if pasteArmed == slot { insideClickTicket = true }
    }

    /// 右键弹出的小菜单：哪个框、弹在框内哪个位置（左上原点，单位 pt）。
    /// 用户 2026-10-27：右键**不直接粘贴**，只激活 + 冒出这个两选一的小菜单。
    @Published var pasteMenuSlot: Slot?
    @Published var pasteMenuPoint: CGPoint = .zero

    /// 右键：激活这个框，并在鼠标位置冒出「粘贴 / 取消」小菜单
    func openPasteMenu(_ slot: Slot, at point: CGPoint) {
        armPaste(slot)
        pasteMenuPoint = point
        pasteMenuSlot = slot
    }

    func closePasteMenu() { pasteMenuSlot = nil }

    /// 短提示：粘贴被拒、数量超限之类。渐显出现，停 2.7 秒后渐隐。
    /// `toastSlot` 记住这句话是哪个框说的 —— 提示要落在那个框的正中心（用户 2026-10-27 要求）。
    @Published var toast: String?
    @Published var toastSlot: Slot?
    private var toastItem: DispatchWorkItem?

    /// 点开预览的那张卡片。图片放大看内容，文档放大看完整信息。
    /// 点一下放大后的内容就关掉（用户 2026-10-27 要求）。
    @Published var previewItem: UploadItem?
    @Published var login = LoginStatus()
    @Published var isRunning = false
    @Published var progress = ProgressInfo()
    @Published var diagnostics = ""
    @Published var autoSend = true
    @Published var progressLines: [String] = []
    /// 一进失败态就把原因补进运行日志（用户 2026-10-27：
    /// **不要再单独导出 md / 截图，也不要在生成框里换按钮** —— 失败成功都只在「详情」里看）。
    /// 挂 didSet 而不是在每个失败分支里各写一次 —— 失败出口有六七个，漏一个就少一条日志。
    @Published var docx: DocxState = .idle {
        didSet {
            if case .failed(let why) = docx { log("✗ 生成失败：\(why)") }
        }
    }
    /// 用户点了「中止」
    @Published var stopRequested = false

    /// 登录倒计时（0 表示没在倒计时）
    @Published var loginCountdown = 0

    /// 第一次检测有结论之前不显示「登录」按钮 —— 否则一开 App 就闪一下"未登录"，很吓人
    @Published var loginSettled = false

    /// 双绿灯（已登录 + 深度思考/智能搜索已激活）之后 0.5 秒才放出「登出 DeepSeek」按钮。
    /// 延迟是为了不让「登录成功」和「冒出新按钮」发生在同一瞬间 —— 那样看着像闪了一下。
    @Published var logoutReady = false
    private var logoutWorkItem: DispatchWorkItem?
    /// 兜底：已登录但模式迟迟没激活（网页改版、检测一直失败）时，到点也把按钮放出来。
    /// 没有这个兜底，用户就没有任何登出入口 —— 底部那个「⋯」菜单已经删了。
    private var logoutFallbackItem: DispatchWorkItem?
    /// 双绿灯达成到按钮出现之间等多久（用户 2026-10-27 定的 0.5 秒）
    private static let logoutDelay: TimeInterval = 0.5
    /// 只有已登录、模式还没激活时，最多等这么久就把按钮放出来
    private static let logoutFallbackDelay: TimeInterval = 8
    /// 按钮淡入时长
    private static let logoutFade: TimeInterval = 0.5

    /// 深度思考 / 智能搜索 的激活状态（在登录流程里探测，供 idleStatus 显示）
    @Published var deepThinkOn = false
    @Published var smartSearchOn = false
    /// 把模式检查单独展示出来，不能把“登录成功”伪装成“两个模式已就绪”。
    @Published var modeCheckDetail = "正在等待 DeepSeek 输入区加载"

    /// 只有在两个开关都由页面复检为开启后才置 true。页面首次渲染较慢时，下一次
    /// 登录探针会自然重试，不能在“尚未找到按钮”时就永久放弃。
    private var modesChecked = false
    private var modesCheckInFlight = false
    /// “重新检查”蓝字按钮只在绿灯亮起 5 秒后仍未激活时才出现。
    /// 绿灯刚亮那几秒，模式检测即使失败也不出重试字样、不出按钮，
    /// 只在后台每轮探针自动重试，直到 5 秒定时器把这个开关打开。
    @Published var modesRetryAllowed = false
    private var modeRetryWorkItem: DispatchWorkItem?

    enum Engine: String, CaseIterable, Identifiable {
        case webview = "内置浏览器"
        case safari = "Safari"
        var id: String { rawValue }
    }

    /// Safari 通道保留着（万一以后内置浏览器出问题可以切回去），界面上不再暴露
    @Published var engine: Engine = .webview
    let browser = BrowserController()

    /// 浏览器当前是不是为了登录而露出来的
    private var browserShownForLogin = false
    private var countdownTimer: Timer?
    /// 退出后等待确认：退出时先把登录行打回“正在检测”，
    /// 探针第一次明确说已退出之前，登录按钮和提示字都不出现，
    /// 期间探针偶尔误判成已登录也直接忽略，不翻状态、不启动倒计时。
    /// 这样退出后按钮只出现一次，不会先出现、消失一秒、再出现。
    /// 登录行永远不显示倒计时，倒计时只在内置网页徽标里。
    private var awaitingLogoutConfirmation = false

    /// 统一的 JS 执行入口：内置浏览器 / Safari 两条通道
    func js(_ code: String) throws -> String {
        switch engine {
        case .webview:
            if browser.currentURL.isEmpty { return "__NO_PAGE__" }
            if !browser.currentURL.contains("deepseek") {
                return "__WRONG_PAGE__" + browser.currentURL
            }
            return try browser.evaluateSync(code)
        case .safari:
            return try SafariBridge.doJS(code)
        }
    }

    /// 技术日志：只进内存，不再往界面上贴
    func log(_ line: String) {
        if Thread.isMainThread {
            progressLines.append(line)
            if progressLines.count > 400 { progressLines.removeFirst(200) }
        } else {
            DispatchQueue.main.async { self.log(line) }
        }
    }

    /// 面向用户的进度播报（线程安全）
    func say(_ title: String,
             detail: String = "",
             fraction: Double = 0,
             running: Bool = false,
             tone: ProgressInfo.Tone = .idle) {
        let apply: () -> Void = { [weak self] in
            self?.progress = ProgressInfo(title: title, detail: detail,
                                          fraction: fraction, running: running, tone: tone)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// 短提示条：渐显 → 停 `seconds` 秒 → 渐隐。
    /// `slot` 决定它落在哪个上传框的正中心；不传就退回窗口顶部（目前没有这种用法）。
    /// 重复调用会重置计时（不叠着弹），`toastItem` 保证只有一个在排队。
    func showToast(_ text: String, seconds: TimeInterval = 2.7, slot: Slot? = nil) {
        toastItem?.cancel()
        toastSlot = slot
        withAnimation(.easeOut(duration: 0.18)) { toast = text }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.toastItem = nil
            withAnimation(.easeIn(duration: 0.3)) {
                self.toast = nil
                self.toastSlot = nil
            }
        }
        toastItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// 用户点了提示条：立刻收走，渐隐速度和渐显一样（0.18 秒）。
    /// 自动消失仍走原来的 0.3 秒，两种节奏不一样是故意的 —— 手点的要跟手。
    func dismissToast() {
        guard toast != nil else { return }
        toastItem?.cancel()
        toastItem = nil
        withAnimation(.easeOut(duration: 0.18)) {
            toast = nil
            toastSlot = nil
        }
    }

    // MARK: - 卡片预览

    func openPreview(_ item: UploadItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            previewItem = item
        }
    }

    func closePreview() {
        guard previewItem != nil else { return }
        withAnimation(.easeOut(duration: 0.18)) { previewItem = nil }
    }

    private var timer: Timer?
    private var pollBusy = false
    private var pollingStopped = false

    /// 选文件面板收哪些类型。pdf 是整份试卷，png / jpg 是扫描件、拍照、截图。
    static let uploadTypes: [UTType] = {
        var types: [UTType] = []
        for ext in ["pdf", "png", "jpg"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types.isEmpty ? [.data] : types
    }()

    deinit {
        timer?.invalidate()
        countdownTimer?.invalidate()
    }

    /// 框里有东西就能开始 —— 一张图片也算，一份 PDF 也算。
    var canGenerate: Bool {
        !items(for: .paper).isEmpty && loginSettled && login.isLoggedIn && !isRunning
    }

    var hintText: String {
        if login.kind == .jsDisabled {
            return "Safari 少一个开关：设置 → 开发 → 允许来自 Apple 事件的 JavaScript"
        }
        if items(for: .paper).isEmpty {
            return "先把试卷的图片或 PDF 放进上传框"
        }
        if !loginSettled { return "" }
        if !login.isLoggedIn { return "先点「登录 DeepSeek」，登录一次以后就不用再登" }
        return ""
    }

    var modeStatusText: String? {
        guard login.isLoggedIn else { return nil }
        if modesChecked { return "深度思考、联网搜索已激活" }
        if modesCheckInFlight { return "正在检查深度思考、联网搜索…" }
        return modeCheckDetail
    }

    var modesReady: Bool { modesChecked }
    var modesChecking: Bool { modesCheckInFlight }

    /// 空闲时状态框的文案：没文件 → 已就绪但没登录 → 全就绪。
    var idleStatus: IdleStatus {
        let count = items(for: .paper).count
        guard count > 0 else {
            return IdleStatus(
                title: "等待上传试卷",
                detail: "把整份试卷放进来：多张图片一次选完，或者一个 PDF；两类不能混放。",
                fraction: 0)
        }
        let kindText = items(for: .paper).first?.kind == .image ? "\(count) 张图片" : "1 个 PDF"
        if !loginSettled {
            return IdleStatus(
                title: "试卷已就绪（\(kindText)）",
                detail: "正在确认登录状态，请稍候。",
                fraction: 0.72)
        }
        if !login.isLoggedIn {
            return IdleStatus(
                title: "试卷已就绪（\(kindText)）",
                detail: "请先登录 DeepSeek 账号，登录成功后即可开始识别。",
                fraction: 0.72)
        }
        // 登录后把深度思考/智能搜索状态拼进标题
        var title = "准备就绪（\(kindText)）"
        var modes: [String] = []
        if deepThinkOn { modes.append("深度思考") }
        if smartSearchOn { modes.append("智能搜索") }
        if !modes.isEmpty {
            title += "　\(modes.joined(separator: "、")) 已激活"
        }
        return IdleStatus(
            title: title,
            detail: "点击上方「开始识别」即可把试卷转成 Word。",
            fraction: 1)
    }

    // MARK: - 登录

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshLogin()
        }
        if engine == .webview { browser.loadDeepSeek() }
        refreshLogin()
        // 兜底：万一页面一直加载不出来，20 秒后也把「登录」按钮放出来，
        // 不然用户会一直卡在"正在检测"，没有出口
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            // 退出等待确认时不放行：按钮要等探针确认已退出才出现，
            // 这里只给正常启动检测兜底，不给退出检测兜底。
            guard let self = self, !self.awaitingLogoutConfirmation else { return }
            self.loginSettled = true
        }
    }

    func refreshLogin() {
        guard !pollingStopped, !pollBusy, !isRunning else { return }
        pollBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = self.probeLogin()
            DispatchQueue.main.async {
                self.pollBusy = false
                // 退出等待确认期间：只有明确说已退出才放行、翻状态；
                // 其它结果（包括偶尔误判成已登录）一律忽略，登录行继续显示“正在检测”，
                // 不翻绿点、不出按钮、不启动倒计时，按钮只在确认后出现一次。
                if self.awaitingLogoutConfirmation {
                    if result.0.kind == .loggedOut {
                        self.awaitingLogoutConfirmation = false
                        self.login = result.0
                        self.diagnostics = result.1
                        self.loginSettled = true
                        self.reactToLoginState()
                    }
                    return
                }
                let wasLoggedIn = self.login.isLoggedIn
                self.login = result.0
                self.diagnostics = result.1
                if result.0.kind == .noPermission { self.pollingStopped = true }
                if AppState.isDefinite(result.0.kind) { self.loginSettled = true }
                // 先后顺序：绿灯先亮，模式检测后开始，不要和绿灯同一轮探针一起跑。
                // 第一轮刚变已登录时只亮绿灯、不跑模式检测，下一轮探针（已登录已稳定）
                // 才开始检测，这样刚登录那一两秒页面还没准备好时，不会立刻冒出重试。
                if result.0.kind == .loggedIn {
                    if !wasLoggedIn {
                        self.modeCheckDetail = "正在等待 DeepSeek 输入区加载"
                        self.scheduleModeRetryTimer()
                    } else if !self.modesChecked && !self.modesCheckInFlight {
                        print("[DEBUG] refreshLogin: 已登录已稳定，检查深度思考和智能搜索")
                        self.ensureDeepSeekModes()
                    }
                } else {
                    self.modesRetryAllowed = false
                    self.modeRetryWorkItem?.cancel()
                    self.modeRetryWorkItem = nil
                }
                self.reactToLoginState()
                // 每轮探针都顺手校准一次「登出 DeepSeek」按钮的放行状态：
                // 退出登录时它要立刻消失。幂等，不会重复计时。
                self.syncLogoutGate()
            }
        }
    }

    /// 这些状态是"问清楚了"的，可以据此决定要不要显示登录按钮。
    /// `.noPage` / `.unknown` 只是还没查出来，继续等。
    private static func isDefinite(_ kind: LoginStatus.Kind) -> Bool {
        switch kind {
        case .loggedIn, .loggedOut, .wrongPage, .noSafari, .noWindow, .noPermission, .jsDisabled:
            return true
        case .noPage, .unknown:
            return false
        }
    }

    /// 登录状态一变，决定要不要开始倒计时收窗口。
    /// 登录成功后顺便把「深度思考」和「智能搜索」都激活（这两个状态在对话间会传递，
    /// 只要开一次就行，所以趁登录时一并处理）。
    private func reactToLoginState() {
        guard browserShownForLogin else { return }
        if login.isLoggedIn {
            // 模式检测不在这里启动：refreshLogin 已经按“绿灯先亮、下一轮再检测”
            // 的顺序管了，这里再调会绕过那个顺序，刚登录就和绿灯一起跑。
            // 退出等待确认期间的误判根本到不了这里（refreshLogin 已拦住），
            // 所以这里不用再连续数两次、三次：一次已登录就启动倒计时收窗口。
            // 倒计时只在内置网页徽标里显示，登录行永远不显示倒计时数字。
            startLoginCountdown()
        } else {
            if let timer = countdownTimer {
                timer.invalidate()
                countdownTimer = nil
                loginCountdown = 0
            }
            pushBadge("正在等待登录…  登录成功后本窗口会自动收起")
        }
    }

    /// 绿灯亮起后 5 秒，才允许出现“重新检查”。5 秒内即使模式没激活，
    /// 也只在后台自动重试，不出重试字样、不出按钮；5 秒后仍未激活，
    /// 定时器把 modesRetryAllowed 打开，按钮和重试文案才出现。
    private func scheduleModeRetryTimer() {
        modeRetryWorkItem?.cancel()
        modesRetryAllowed = false
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.login.isLoggedIn, !self.modesChecked else { return }
            self.modesRetryAllowed = true
        }
        modeRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// 登录成功后，确保深度思考 + 智能搜索都已激活。
    /// 如果本来就是开的，状态栏提示「已激活」；如果 App 帮点了，提示「已开启」。
    private func ensureDeepSeekModes() {
        guard !modesChecked, !modesCheckInFlight else { return }
        modesCheckInFlight = true
        modeCheckDetail = "正在检查深度思考、联网搜索…"
        print("[DEBUG] ensureDeepSeekModes: 开始探测")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var finalDeepThink = false
            var finalSmartSearch = false
            var deepThinkFound = false
            var smartSearchFound = false
            var errorDescription: String?
            do {
                let probe = try self.js(Scripts.probeComposer)
                print("[DEBUG] probeComposer 返回: \(probe)")
                guard let data = probe.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { throw BridgeError.failed("无法解析输入区开关状态") }
                let dt = obj["deepThink"] as? Bool ?? false
                let ss = obj["smartSearch"] as? Bool ?? false
                deepThinkFound = obj["deepThinkFound"] as? Bool ?? false
                smartSearchFound = obj["smartSearchFound"] as? Bool ?? false
                print("[DEBUG] deepThink=\(dt), smartSearch=\(ss)")
                var requested: [String] = []

                if !dt, let (x, y) = Self.modeRect(obj["deepThinkRect"]) {
                    print("[DEBUG] 点击深度思考: (\(x), \(y))")
                    if self.clickBrowserMode(at: x, y: y) { requested.append("深度思考") }
                } else {
                    if !dt { print("[DEBUG] 深度思考未激活且找不到坐标") }
                }

                if !ss, let (x, y) = Self.modeRect(obj["smartSearchRect"]) {
                    print("[DEBUG] 点击智能搜索: (\(x), \(y))")
                    if self.clickBrowserMode(at: x, y: y) { requested.append("智能搜索") }
                } else {
                    if !ss { print("[DEBUG] 智能搜索未激活且找不到坐标") }
                }

                // 不能把“已发出点击”当作“已开启”：等页面处理事件后重新探测确认。
                if !requested.isEmpty { Thread.sleep(forTimeInterval: 0.9) }
                let verified = try self.js(Scripts.probeComposer)
                guard let verifiedData = verified.data(using: .utf8),
                      let verifiedObj = (try? JSONSerialization.jsonObject(with: verifiedData)) as? [String: Any]
                else { throw BridgeError.failed("无法复检输入区开关状态") }
                finalDeepThink = verifiedObj["deepThink"] as? Bool ?? false
                finalSmartSearch = verifiedObj["smartSearch"] as? Bool ?? false
                deepThinkFound = verifiedObj["deepThinkFound"] as? Bool ?? deepThinkFound
                smartSearchFound = verifiedObj["smartSearchFound"] as? Bool ?? smartSearchFound
                print("[DEBUG] 开关复检: deepThink=\(finalDeepThink), smartSearch=\(finalSmartSearch)")
            } catch {
                print("[DEBUG] ensureDeepSeekModes 异常: \(error)")
                errorDescription = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.modesCheckInFlight = false
                self.deepThinkOn = finalDeepThink
                self.smartSearchOn = finalSmartSearch
                self.modesChecked = finalDeepThink && finalSmartSearch
                // 第二个绿灯就在这里亮起来 —— 立刻开始算「登出」按钮那 0.5 秒延迟。
                // 不能等下一轮登录探针（2 秒后）再算，那样按钮要 2.5 秒才出现。
                self.syncLogoutGate()
                if self.modesChecked {
                    // 登录流程结束后进度卡会回到 idleStatus；由它统一显示“已激活”，
                    // 不留一条成功提示遮住空闲状态框。
                    print("[DEBUG] 深度思考、智能搜索均已激活")
                } else if let errorDescription {
                    // 5 秒内不出“重试”字样，只说在等页面；5 秒后仍失败，才说重试。
                    self.modeCheckDetail = self.modesRetryAllowed ? "模式检查暂时失败，正在重试" : "正在等待页面加载"
                    print("[DEBUG] 开关检查将重试：\(errorDescription)")
                } else {
                    if !deepThinkFound || !smartSearchFound {
                        self.modeCheckDetail = "未识别到模式开关，正在等待页面加载"
                    } else {
                        self.modeCheckDetail = self.modesRetryAllowed ? "模式尚未确认开启，正在重试" : "模式尚未确认开启，正在等待页面加载"
                    }
                    print("[DEBUG] 开关尚未全部就绪，将在下一次登录探针时重试")
                }
            }
        }
    }

    /// JSONSerialization 会把坐标对象桥接成 `[String: Any]` / `NSNumber`，不能直接
    /// 转成 `[String: Double]`。这是 v0.17 找得到按钮却无法点击的根因。
    private static func modeRect(_ value: Any?) -> (CGFloat, CGFloat)? {
        guard let rect = value as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue,
              let y = (rect["y"] as? NSNumber)?.doubleValue,
              x.isFinite, y.isFinite else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    /// `clickAtViewportPoint` 会操作 NSWindow，必须在主线程做；模式探测本身则留在
    /// 后台，避免等待 WebKit 回调时卡住界面。
    private func clickBrowserMode(at x: CGFloat, y: CGFloat) -> Bool {
        if Thread.isMainThread { return browser.clickAtViewportPoint(x: x, y: y) }
        var clicked = false
        DispatchQueue.main.sync { [weak self] in
            clicked = self?.browser.clickAtViewportPoint(x: x, y: y) ?? false
        }
        return clicked
    }

    /// 让用户可以在网页改版、或网络导致首次页面晚到时主动重新跑一次检查。
    func retryDeepSeekModes() {
        guard login.isLoggedIn, !modesCheckInFlight else { return }
        modesChecked = false
        deepThinkOn = false
        smartSearchOn = false
        ensureDeepSeekModes()
    }

    private func startLoginCountdown() {
        guard countdownTimer == nil else { return }
        loginCountdown = 5
        pushBadge("✓ 登录成功，\(loginCountdown) 秒后自动收起本窗口")
        say("登录成功", detail: "窗口将在 \(loginCountdown) 秒后自动收起，不用管它",
            running: false, tone: .ok)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.loginCountdown -= 1
            if self.loginCountdown <= 0 {
                t.invalidate()
                self.countdownTimer = nil
                self.finishLogin()
            } else {
                self.pushBadge("✓ 登录成功，\(self.loginCountdown) 秒后自动收起本窗口")
            }
        }
    }

    private func finishLogin() {
        // 登录成功倒计时走完才到这里，正常情况仍收起窗口，逻辑不动。
        // 但如果倒计时还没走完用户就退出了（或退出后残留的旧倒计时走完），
        // 此时已经是未登录，登录窗口是留给用户重新登录用的，不能再收起它。
        let stillLoggedIn = login.isLoggedIn
        browserShownForLogin = false
        if stillLoggedIn { pushBadge("✓ 已登录") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // 徽标不管怎样都要清掉，否则退出后网页上还残留“x 秒后自动收起”；
            // 窗口只在登录成功时收起，退出后留给重新登录用，不收。
            self.clearBadge()
            if stillLoggedIn {
                self.browser.hideCompletely()
            }
        }
        // 回到空闲状态框，标题会根据 deepThinkOn / smartSearchOn 显示开关状态。
        progress = ProgressInfo()
    }

    private func pushBadge(_ text: String) {
        guard engine == .webview else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.js(Scripts.loginBadge(text: text))
        }
    }

    private func clearBadge() {
        guard engine == .webview else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.js(Scripts.loginBadgeClear)
        }
    }

    /// 打开浏览器让用户登录（这是全 App 唯一会露出窗口的地方）
    func openDeepSeek() {
        switch engine {
        case .webview:
            browser.loadDeepSeek(force: false)
            browser.showForUser()
            browserShownForLogin = true
            pushBadge("正在等待登录…  登录成功后本窗口会自动收起")
            say("请在打开的窗口里登录 DeepSeek",
                detail: "登录成功后窗口会自动收起，不用手动关", running: false)
        case .safari:
            SafariBridge.openDeepSeek()
            say("正在打开 chat.deepseek.com，请在 Safari 里完成登录", running: false)
        }
        pollingStopped = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshLogin()
        }
    }

    /// 双绿灯一变，就重新安排「登出 DeepSeek」按钮的出现时机。**幂等**，每轮登录探针都能调：
    /// 已经在等那 0.5 秒的不会重新计时，已经亮了的不会重复亮。
    private var logoutAllowed: Bool {
        loginSettled && login.isLoggedIn && modesChecked
    }

    private func syncLogoutGate() {
        let loggedIn = loginSettled && login.isLoggedIn
        guard loggedIn else {
            logoutWorkItem?.cancel()
            logoutWorkItem = nil
            logoutFallbackItem?.cancel()
            logoutFallbackItem = nil
            if logoutReady {
                // 退出登录：按钮淡出
                withAnimation(.easeOut(duration: Self.logoutFade)) { logoutReady = false }
            }
            return
        }
        // 只要登录了就先把兜底计时器挂上 —— 万一模式一直检测不出来，
        // 到点仍然能给用户一个登出入口（底部那个「⋯」已经删了，没有别的路）。
        scheduleLogoutFallback()
        guard logoutAllowed else { return }
        guard !logoutReady, logoutWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logoutWorkItem = nil
            guard self.logoutAllowed else { return }
            // 渐显：按钮从无到有，0.5 秒淡入
            withAnimation(.easeOut(duration: Self.logoutFade)) { self.logoutReady = true }
        }
        logoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logoutDelay, execute: item)
    }

    /// 已登录、但双绿灯迟迟不达成时的兜底。
    /// 只在本次登录会话里挂一次：按钮已经亮了就什么都不做。
    private func scheduleLogoutFallback() {
        guard !logoutReady, logoutFallbackItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logoutFallbackItem = nil
            guard self.loginSettled, self.login.isLoggedIn, !self.logoutReady else { return }
            self.log("模式检测 \(Int(Self.logoutFallbackDelay)) 秒未完成，「登出」按钮按兜底放出")
            withAnimation(.easeOut(duration: Self.logoutFade)) { self.logoutReady = true }
        }
        logoutFallbackItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logoutFallbackDelay, execute: item)
    }

    /// 主界面右上角的「登出 DeepSeek」按钮 —— 点它只弹确认框，
    /// 真正清登录态在确认后的 `logoutDeepSeek()`（和退出 App 确认框
    /// 一样：主界面绝对居中、整框玻璃、按钮玻璃），不用 NSAlert 系统弹窗。
    /// 生成进行中时确认框里的登出按钮是禁用的。

    /// 真的清登录态。清完直接把登录窗口弹出来，用户不用再找按钮。
    func logoutDeepSeek() {
        say("正在登出 DeepSeek 账号…", detail: "清掉本机保存的登录信息", running: true)
        // 先停掉探针和倒计时，免得旧状态干扰新登录流程
        timer?.invalidate()
        timer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        loginCountdown = 0
        awaitingLogoutConfirmation = true
        browserShownForLogin = false
        modesChecked = false
        modesCheckInFlight = false
        modesRetryAllowed = false
        modeRetryWorkItem?.cancel()
        modeRetryWorkItem = nil
        deepThinkOn = false
        smartSearchOn = false
        modeCheckDetail = "正在等待 DeepSeek 输入区加载"

        // 登出：「登出 DeepSeek」按钮立刻收掉，等重新登录 + 双绿灯后再出现。
        // 这里直接置 false、不做淡出 —— 登出是一次明确的动作，按钮留着淡出反而拖沓。
        // 兜底计时器也要一起取消，否则它会在重新登录后的第 8 秒把按钮提前放出来。
        logoutWorkItem?.cancel()
        logoutWorkItem = nil
        logoutFallbackItem?.cancel()
        logoutFallbackItem = nil
        logoutReady = false

        // 把状态框重置回「等待检测」，否则退出后还显示"已登录"
        progress = ProgressInfo()

        browser.clearWebsiteData { [weak self] in
            guard let self = self else { return }
            // 不要在这里立刻把状态写成已退出：清数据回调时页面还是旧的，
            // 立刻写已退出会让登录按钮瞬间出现，下一轮探针误判已登录又把它藏起来，
            // 再下一轮才重新出现，就是用户报的“出现、消失一秒、再出现”。
            // 这里只打回“正在检测”，按钮和提示字等 refreshLogin 探针确认已退出才出现。
            self.login = LoginStatus(kind: .unknown)
            self.loginSettled = false
            self.pollingStopped = false
            self.say("已登出 DeepSeek 账号", detail: "请在打开的窗口里重新登录",
                    running: false, tone: .ok)
            self.openDeepSeek()
            // 清完数据后探针被停了，必须重新启动，否则登录成功没人发现
            self.startPolling()
        }
    }

    func showJSHelp() {
        let alert = NSAlert()
        alert.messageText = "需要在 Safari 里打开一个开关"
        alert.informativeText = """
        1. 打开 Safari，菜单栏点「Safari」→「设置…」（⌘,）
        2. 切到「高级」标签，勾选「显示网页开发者功能」
        3. 再切到「开发」标签，勾选「允许来自 Apple 事件的 JavaScript」

        打开后本 App 会在 3 秒内自动恢复，不用重启 App。
        """
        alert.addButton(withTitle: "打开 Safari")
        alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
        }
    }

    func probeLogin() -> (LoginStatus, String) {
        do {
            let raw = try js(Scripts.loginProbe)
            if raw == "__NO_SAFARI__" { return (LoginStatus(kind: .noSafari), raw) }
            if raw == "__NO_WINDOW__" { return (LoginStatus(kind: .noWindow), raw) }
            if raw == "__NO_PAGE__" { return (LoginStatus(kind: .noPage), raw) }
            if raw.hasPrefix("__WRONG_PAGE__") {
                return (LoginStatus(kind: .wrongPage, detail: String(raw.dropFirst(15))), raw)
            }
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return (LoginStatus(kind: .unknown, detail: raw), raw)
            }
            let hasChat = obj["hasChatInput"] as? Bool ?? false
            let hasLoginForm = obj["hasLoginForm"] as? Bool ?? false
            let hasLoginButton = obj["hasLoginButton"] as? Bool ?? false
            let bodyLen = obj["bodyLen"] as? Int ?? 0
            let keys = obj["keys"] as? [String] ?? []
            let fileInputs = obj["fileInputs"] as? Int ?? 0
            let diag = "localStorage: \(keys.prefix(8).joined(separator: ", "))\n"
                + "chatInput=\(hasChat)  loginForm=\(hasLoginForm)  loginBtn=\(hasLoginButton)"
                + "  fileInput=\(fileInputs)  bodyLen=\(bodyLen)"

            if hasChat && !hasLoginForm { return (LoginStatus(kind: .loggedIn), diag) }
            if hasLoginForm || hasLoginButton { return (LoginStatus(kind: .loggedOut), diag) }
            // 既没有输入框也没有登录入口 —— 多半是页面还没渲染完，别急着下结论。
            // 早期版本在这里直接返回 loggedOut，导致 App 一启动就闪一下"未登录"。
            if bodyLen < 80 { return (LoginStatus(kind: .noPage), diag) }
            return (LoginStatus(kind: .unknown, detail: "页面有内容但认不出登录状态"), diag)
        } catch let err {
            let msg = err.localizedDescription
            if msg.contains("Allow JavaScript from Apple Events") || msg.contains("do JavaScript") {
                return (LoginStatus(kind: .jsDisabled), msg)
            }
            if let be = err as? BridgeError, case .denied = be {
                return (LoginStatus(kind: .noPermission), msg)
            }
            return (LoginStatus(kind: .unknown, detail: msg), msg)
        }
    }

    // MARK: - 文件选择（带目录记忆）

    private static func dirKey(_ slot: Slot) -> String {
        "pickDir.paper"
    }

    /// 上次选文件的目录：本框上次的目录 → 共享目录 → 下载目录
    private func startDirectory(for slot: Slot) -> URL? {
        let ud = UserDefaults.standard
        let candidates = [AppState.dirKey(slot), "pickDir.shared"]
        for key in candidates {
            if let path = ud.string(forKey: key) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func rememberDirectory(_ url: URL, slot: Slot) {
        let dir = url.deletingLastPathComponent().path
        let ud = UserDefaults.standard
        ud.set(dir, forKey: AppState.dirKey(slot))
        ud.set(dir, forKey: "pickDir.shared")
    }

    func chooseFile(for slot: Slot) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // 允许多选：整份试卷常常是十几二十张照片，一次挑完省得反复开面板。
        // 超限的那些会被 addUpload 挡掉并冒泡说明原因。
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AppState.uploadTypes
        panel.message = "支持 png / jpg 图片（可多选）或 1 个 PDF，两类不能混放"
        panel.prompt = "选择"
        panel.title = "选择试卷图片或 PDF"
        panel.isExtensionHidden = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = startDirectory(for: slot)

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self, response == .OK else { return }
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            // 和粘贴 / 拖放同一套：一次选一堆也走 acceptBatch，
            // 重复的、类型不对的、超上限的都汇总成一条提示。
            self.acceptBatch(urls, for: slot)
            if let first = urls.first { self.rememberDirectory(first, slot: slot) }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    // MARK: - 上传框内容（图片 / PDF）

    /// 图片最多几张、PDF 最多几个。
    /// 试卷是「大批量图片」，上限 **48 张**（用户 2026-10-29 定：正好 8 行 × 每行 6 个，
    /// 预览区最多铺 8 行，再多就超出这个上限了）；PDF 只允许 1 个 —— 一份 PDF 就是整份试卷。
    static func limits(for slot: Slot) -> (images: Int, docs: Int) {
        (images: 48, docs: 1)
    }

    /// 剪贴板图片的下一个名字：`剪贴板图片1`、`剪贴板图片2`……（不带 `-`）
    ///
    /// 只数**框里当前还在的**剪贴板图片，上传的文件不算（它们自带文件名）。
    /// 取「当前没被占用的最小正整数」，所以删掉中间一张再粘，序号会补回空位，不会一直涨。
    func nextPasteName() -> String {
        var used = Set<Int>()
        for (_, list) in uploads {
            for item in list where item.isPaste {
                if let n = Self.pasteIndex(item.name) { used.insert(n) }
            }
        }
        var i = 1
        while used.contains(i) { i += 1 }
        return "剪贴板图片\(i)"
    }

    /// 从「剪贴板图片3.png」里取出 3
    private static func pasteIndex(_ name: String) -> Int? {
        let head = "剪贴板图片"
        guard name.hasPrefix(head) else { return nil }
        let digits = name.dropFirst(head.count).prefix { $0.isNumber }
        return Int(digits)
    }

    func items(for slot: Slot) -> [UploadItem] { uploads[slot] ?? [] }

    /// 还能不能再放一个 `kind`：能放返回 nil，不能放返回给用户看的拒绝理由。
    /// 两条硬规矩：同一个框里不许混放；同类不超过上限。
    func uploadRejection(for slot: Slot, adding kind: UploadItem.Kind) -> String? {
        let current = items(for: slot)
        let caps = AppState.limits(for: slot)
        if let first = current.first, first.kind != kind {
            return first.kind == .image
                ? "框里已经有图片了，PDF 和图片不能混放"
                : "框里已经有一个 PDF 了，图片和 PDF 不能混放"
        }
        let sameKind = current.filter { $0.kind == kind }.count
        let cap = kind == .image ? caps.images : caps.docs
        guard sameKind < cap else {
            return kind == .image
                ? "最多 \(cap) 张图片，先移除一张再放"
                : "PDF 只能放 1 个，先移除再放"
        }
        return nil
    }

    /// 放进框里的结果
    enum AddOutcome { case added, duplicate, rejected }

    /// 这个文件是不是已经在框里了 —— **按内容指纹比，不按文件名**。
    /// 指纹算不出来的（空串）一律当「不重复」，宁可可重复也不误拒。
    func isDuplicate(_ item: UploadItem, for slot: Slot) -> Bool {
        guard !item.fingerprint.isEmpty else { return false }
        return items(for: slot).contains { $0.fingerprint == item.fingerprint }
    }

    /// 重复文件的提示。用户 2026-10-29 第 4 轮第 3 条：
    /// 「冒泡逻辑参考超过文件数量或种类限制时的提示」—— 同一个 showToast、同一个位置（框中心）。
    func duplicateToast(_ count: Int) -> String {
        count <= 1
            ? "这个文件已经在框里了，没有重复放进来"
            : "有 \(count) 个文件已经在框里了，已跳过"
    }

    /// 放进框里。放不进去就弹短提示并说明原因。
    ///
    /// **判重在最前面**（用户 2026-10-29 第 4 轮第 3 条）：
    /// 重复的文件直接不收，也**绝不删掉框里原来那个** —— 只丢新来的这份。
    /// `quietDuplicate` 给批量粘贴/批量选择用：重复的不逐个冒泡，
    /// 由调用方汇总成一条「有 N 个文件已经在框里了」，免得一次粘 4 个弹 4 次。
    @discardableResult
    func addUpload(_ item: UploadItem, for slot: Slot, quietDuplicate: Bool = false) -> AddOutcome {
        if isDuplicate(item, for: slot) {
            if !quietDuplicate { showToast(duplicateToast(1), slot: slot) }
            return .duplicate
        }
        if let reason = uploadRejection(for: slot, adding: item.kind) {
            showToast(reason, slot: slot)
            return .rejected
        }
        uploads[slot, default: []].append(item)
        if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
        return .added
    }

    func removeUpload(_ id: UploadItem.ID, for slot: Slot) {
        if let doomed = uploads[slot]?.first(where: { $0.id == id }) {
            deletePasteFile(for: doomed)
        }
        uploads[slot]?.removeAll { $0.id == id }
        if (uploads[slot] ?? []).isEmpty { uploads[slot] = nil }
        if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
    }

    /// 清空一个框（含「换一个文件」的语义）
    func clearFile(for slot: Slot) {
        for item in items(for: slot) { deletePasteFile(for: item) }
        uploads[slot] = nil
        if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
    }

    // MARK: - 清空（≥6 个要先确认）

    /// 6 个及以上才弹确认框（用户 2026-10-29 第 4 轮第 2 条）。
    /// 少了不值当拦一道，多了点错一次就得重新选一遍。
    static let clearConfirmThreshold = 6

    /// 正在等确认清空的框；nil = 没弹
    @Published var clearConfirmSlot: Slot?

    /// 点「清空」按钮走这里：够多就先问一句，不够直接清。
    func requestClear(for slot: Slot) {
        if items(for: slot).count >= AppState.clearConfirmThreshold {
            clearConfirmSlot = slot
        } else {
            clearFile(for: slot)
        }
    }

    func confirmClear() {
        guard let slot = clearConfirmSlot else { return }
        clearConfirmSlot = nil
        clearFile(for: slot)
    }

    func cancelClear() {
        clearConfirmSlot = nil
    }

    /// 删掉我们落在临时目录里的剪贴板图片。
    /// **只删自己创建的那一份**（路径必须正好在 `pasteDirectory` 下），用户磁盘上的原文件绝不碰。
    private func deletePasteFile(for item: UploadItem) {
        guard let url = item.url,
              url.deletingLastPathComponent().standardizedFileURL == UploadItem.pasteDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 粘贴

    /// ⌘V：从剪贴板往框里放文件或图片。
    /// - 剪贴板里有文件 → 逐个按扩展名收（批量试卷常常一次复制一堆图）
    /// - 没有文件、但有图（截图、网页里复制的图）→ 当作图片收下
    /// 数量 / 种类超限同样拒绝，提示落在上传框的正中心。
    ///
    /// ⚠️ **剪贴板里一旦有文件 URL，就走完这个分支直接 return，绝不再往下试 `NSImage(pasteboard:)`**
    /// （用户 2026-10-29 第 6 轮第 3 条报的致命 bug）：
    /// `NSImage(pasteboard:)` 会把剪贴板上的**文件 URL 当成图片去解** ——
    /// heic / tiff / gif 这些 NSImage 认得、但我们白名单里没有的格式，
    /// 会先被 `UploadItem(url:)` 拒掉，然后又被这一句解成图片塞进预览框。
    /// 结果就是「提示了类型不支持，文件却还是进来了」。
    /// 一批磁盘文件统一入口：**粘贴和拖放共用**，规则完全一致
    /// （类型白名单 / 数量上限 / 不许混放 / 内容判重）。
    ///
    /// 用户 2026-10-29 第 7 轮第 2 条：一批里**同时**有重复的和类型不支持的，
    /// 两个数都要说清楚，别只报一个。
    /// 提示优先级：超上限/混放 > 汇总。
    ///
    /// **卡顿优化（用户 2026-10-29 第 8 轮）**：原来这里是「一个文件 → 建卡片 → append 一次」，
    /// 十个文件就是十次读盘 + 十次解码缩略图 + 十次 `@Published` 变更（每次整张卡片重排一遍）。
    /// 现在拆成两段：`buildItems` 在后台线程把卡片全建好（读盘 / 解码都在那里），
    /// 再一次性交给 `commitBatch` 合并、**只写一次 `uploads`** —— 界面只重排一次。
    func acceptBatch(_ urls: [URL], for slot: Slot) {
        guard !urls.isEmpty else { return }
        if AppState.loadFilesOnMainThread {
            // 自检（--pastetypetest）用：结果要在 exit 之前读到，等不了 main.async
            commitBatch(AppState.buildItems(from: urls), for: slot)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built = AppState.buildItems(from: urls)
            DispatchQueue.main.async { self?.commitBatch(built, for: slot) }
        }
    }

    /// 自检用开关：把「建卡片」拉回主线程同步做完。正式运行永远走后台。
    static var loadFilesOnMainThread = false

    /// 一批 URL 建出来的卡片 + 认不出类型的个数
    struct BuiltBatch {
        var items: [UploadItem] = []
        var unsupported = 0
    }

    /// 只读盘、不碰任何状态：把 URL 变成预览卡片。可以在后台线程跑。
    static func buildItems(from urls: [URL]) -> BuiltBatch {
        var batch = BuiltBatch()
        batch.items.reserveCapacity(urls.count)
        for url in urls {
            if let item = UploadItem(url: url) {
                batch.items.append(item)
            } else {
                batch.unsupported += 1        // 类型不在白名单，直接不收
            }
        }
        return batch
    }

    /// 把一批已经建好的卡片合并进框里：判重 → 查上限/混放 → **一次性 append**。
    private func commitBatch(_ batch: BuiltBatch, for slot: Slot) {
        var duplicates = 0
        var rejection: String?
        var accepted: [UploadItem] = []
        // 边算边攒：`current` 里同时包含「框里原有的」和「本批前面刚收下的」，
        // 这样同一批里自己和自己重复的也能拦住。
        var current = items(for: slot)
        let caps = AppState.limits(for: slot)

        for item in batch.items {
            // 判重在最前面：重复的不收，**绝不删掉框里原来那个**
            if !item.fingerprint.isEmpty,
               current.contains(where: { $0.fingerprint == item.fingerprint }) {
                duplicates += 1
                continue
            }
            if let first = current.first, first.kind != item.kind {
                rejection = first.kind == .image
                    ? "框里已经有图片了，PDF 和图片不能混放"
                    : "框里已经有一个 PDF 了，图片和 PDF 不能混放"
                break
            }
            let sameKind = current.reduce(0) { $0 + ($1.kind == item.kind ? 1 : 0) }
            let cap = item.kind == .image ? caps.images : caps.docs
            guard sameKind < cap else {
                rejection = item.kind == .image
                    ? "最多 \(cap) 张图片，先移除一张再放"
                    : "PDF 只能放 1 个，先移除再放"
                break
            }
            current.append(item)
            accepted.append(item)
        }

        if !accepted.isEmpty {
            uploads[slot, default: []].append(contentsOf: accepted)   // ← 整批只写一次
            if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
        }

        if let rejection {
            showToast(rejection, slot: slot)
            return
        }
        if duplicates > 0 && batch.unsupported > 0 {
            showToast("有 \(duplicates) 个已经在框里了、\(batch.unsupported) 个类型不支持，已跳过", slot: slot)
        } else if duplicates > 0 {
            showToast(duplicateToast(duplicates), slot: slot)
        } else if batch.unsupported > 0 {
            showToast(batch.unsupported == 1
                      ? "这个文件类型不支持，只收 png / jpg 图片或 PDF"
                      : "有 \(batch.unsupported) 个文件类型不支持，已跳过，只收 png / jpg 图片或 PDF",
                      slot: slot)
        }
    }

    /// 把拖进来的 `NSItemProvider` 解析成文件 URL（**保持拖进来的顺序**）。
    /// 全部回来之后再回调 —— 这样「一次拖 5 个、其中 2 个重复 1 个类型不对」
    /// 才能只弹一条汇总提示，而不是弹三次。
    static func resolveFileURLs(from providers: [NSItemProvider],
                                completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else { completion([]); return }
        var slots = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data else { return }
                // 正常是 plist 编码的 NSURL；个别 App 给的是 "file://…" 纯字符串，兜一手
                var url = URL(dataRepresentation: data, relativeTo: nil)
                if url == nil,
                   let text = String(data: data, encoding: .utf8),
                   text.hasPrefix("file://") {
                    url = URL(string: text)
                }
                guard let url else { return }
                lock.lock(); slots[index] = url; lock.unlock()
            }
        }
        group.notify(queue: .main) {
            completion(slots.compactMap { $0 })
        }
    }

    func pasteFromClipboard(into slot: Slot) {
        paste(from: .general, into: slot)
    }

    /// 真正干活的那一层。剪贴板作为参数传进来，自检（`--pastetypetest`）就能用一块私有剪贴板
    /// 复现「粘一个不支持的文件」而不去动用户自己的剪贴板。
    func paste(from pb: NSPasteboard, into slot: Slot) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []

        if !urls.isEmpty {
            // 统一交给 acceptBatch：粘贴 / 拖放 / 批量选文件同一套规则、同一条汇总提示
            acceptBatch(urls, for: slot)
            // 不管收下几个，**文件分支到此为止**，绝不落到下面的图片分支
            return
        }
        if let image = NSImage(pasteboard: pb) {
            let item = UploadItem(image: image, name: nextPasteName())
            // 被拒（重复 / 数量满了）就别在临时目录里留一张没人用的图。
            // 注意：只删**这次新写出来**的这一份，框里原来那张不动。
            if addUpload(item, for: slot) != .added, let url = item.url {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        showToast("剪贴板里没有可用的文件或图片", slot: slot)
    }

    // MARK: - 内置附件

    /// 内置附件：两份规则 md，没有版式模板 —— 版式全在规则里写死了。
    ///
    /// 用户 2026-10-29 第 13 轮：加了「学生手写文章」这条业务线，
    /// 所以规则从一份变两份，**两份都要传给 AI**（提示词里按附件 1 / 附件 2 指代）。
    static var bundledRule: URL? {
        Bundle.main.url(forResource: "试卷识别规则", withExtension: "md")
    }

    static var bundledHandwritingRule: URL? {
        Bundle.main.url(forResource: "学生手写文章转录规则", withExtension: "md")
    }

    /// 请求中止当前流程（用户点「中止」时）
    func requestStop() {
        stopRequested = true
        PythonRunner.cancelCurrent()      // Python 跑起来的时候也能立刻停
        say("正在中止…", running: true)
    }

    // MARK: - 生成

    /// 已经提交出去、但为了防重复生成而从上传框里清掉的文件。
    /// 失败或中止时放回去，用户不用重新选一遍。
    /// 存 `UploadItem` 而不是 URL：缩略图、文件名、大小都跟着回去，界面不会闪一下。
    @Published var heldFiles: [UploadItem]?

    func generate() {
        guard canGenerate else { return }
        runPipeline()
    }

    /// 提交后立刻清空上传框：同一批文件不会被反复提交，也避免误点出第二份成品。
    /// 调用前必须先把文件拷出来（runPipeline 里已拷到局部变量）。
    func submitAndClearUploads() {
        let paper = items(for: .paper)
        guard !paper.isEmpty else { return }
        heldFiles = paper
        uploads[.paper] = nil
        pasteArmed = nil
    }

    /// 失败 / 中止时把文件放回上传框
    func restoreHeldFiles() {
        guard let held = heldFiles else { return }
        if items(for: .paper).isEmpty { uploads[.paper] = held }
        heldFiles = nil
    }

    /// 成功了：这批文件再也用不上，顺手把落在临时目录里的剪贴板图片删掉。
    private func discardHeldFiles() {
        if let held = heldFiles {
            for item in held { deletePasteFile(for: item) }
        }
        heldFiles = nil
    }

    // MARK: - 内置 Python 执行

    @Published var scriptOutput = ""

    /// 运行日志面板（成功、失败都从这里看，见 `LogPanel`）。
    /// 2026-10-27 用户定：失败时**不换按钮、不弹面板、不导 md/截图**，
    /// 一律只在这个面板里看 —— 所以 `progressLines` 是唯一的日志出口。
    @Published var showLog = false

    func openLog() {
        guard !showLog else { return }
        withAnimation(.easeOut(duration: 0.18)) { showLog = true }
    }

    func closeLog() {
        guard showLog else { return }
        withAnimation(.easeOut(duration: 0.18)) { showLog = false }
    }

    func toggleLog() {
        if showLog { closeLog() } else { openLog() }
    }

    /// 开发用：`--logdemo` 造一份像样的日志并把面板打开，
    /// 不用真跑一轮三分钟就能看版式、确认面板没盖住「详情」按钮。
    func applyLogDemo() {
        // 照抄一次真实运行的日志（2026-10-27 第 4 套 PDF 那轮），
        // 演示面板的时候看到的就是真实形态，不是编的。
        progressLines = [
            "页面重载：2.4 秒",
            "等输入框出现：0.4 秒",
            "页面：{\"textarea\":true,\"fileInputs\":1,\"sendLabel\":\"\",\"deepThink\":true,\"smartSearch\":true}",
            "载入 试卷识别规则.md（9 KB）",
            "载入 语文第3套-1.jpg（1.8 MB）",
            "载入 语文第3套-2.jpg（2.1 MB）",
            "载入 语文第3套-3.jpg（1.9 MB）",
            "注入：INPUT:4/0",
            "4 个附件已就位（5.8 MB）",
            "提示词已填入并回读一致（612 字）",
            "发送结果：ENTER",
            "第 1 轮：生成中，已写 1240 字",
            "第 3 轮：生成中，已写 3870 字",
            "代码出现收尾标志：末尾有 .save( 调用",
            "内容 3 秒未变且有收尾标志，按完成处理",
            "抓到 1 个代码块，原文总长 11942 字符",
            "脚本 11943 字符，直接执行",
        ]
        showLog = true
    }

    var pythonReady: Bool { PythonRunner.isAvailable }

    /// 抓到脚本 → 直接跑，不再问用户
    func offerScript(_ code: String) {
        let cleaned = ScriptExtractor.normalize(code)
        guard cleaned.count > 40 else {
            log("没有抓到可用的 Python 脚本")
            say("没有拿到可用的脚本", detail: "可以重试一次", running: false, tone: .error)
            return
        }
        log("脚本 \(cleaned.count) 字符，直接执行")
        runScript(cleaned)
    }

    func runScript(_ code: String) {
        let cleaned = ScriptExtractor.normalize(code)
        guard cleaned.count > 40 else {
            say("脚本内容太短，像是没生成全", running: false, tone: .error)
            return
        }
        isRunning = true
        scriptOutput = ""
        docx = .building
        say("正在把识别结果排成 Word…", detail: "大约需要几十秒，页数多会更久", running: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var payload: RunResult?
            var failure: String?
            do {
                payload = try PythonRunner.run(script: cleaned)
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.isRunning = false
                if let failure = failure {
                    self.docx = .failed(failure)
                    self.scriptOutput = failure
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
                             running: false, tone: .error)
                    return
                }
                guard let result = payload else { return }
                self.scriptOutput = result.output.isEmpty ? "（脚本没有任何输出）" : result.output

                if result.cancelled {
                    self.docx = .idle
                    self.restoreHeldFiles()
                    self.say("已中止", detail: "试卷没有生成，文件已放回上传框，可以重新来一次",
                             running: false)
                    return
                }
                if result.timedOut {
                    self.docx = .failed("执行超时（4 分钟）")
                    self.restoreHeldFiles()
                    self.say("生成超时了", detail: "脚本跑了 4 分钟还没结束，已强制停下",
                             running: false, tone: .error)
                    return
                }
                if result.exitCode != 0 {
                    let msg = "脚本报错（退出码 \(result.exitCode)）"
                    self.docx = .failed(msg)
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
                             running: false, tone: .error)
                    return
                }
                let docs = result.producedFiles.filter { $0.pathExtension.lowercased() == "docx" }
                guard !docs.isEmpty else {
                    self.docx = .failed("没有产出 docx")
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "脚本跑完了，但没有产出 Word 文件",
                             running: false, tone: .error)
                    return
                }
                if let stored = self.storeProduced(docs) {
                    self.docx = .ready(stored)
                    self.discardHeldFiles()       // 成功了就不再需要"放回去"，剪贴板图片也一并清掉
                    self.say("Word 试卷生成好了 ✓", detail: "在下面点「下载 Word 试卷」保存到电脑里",
                             running: false, tone: .ok)
                } else {
                    self.docx = .failed("无法保存产物")
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "文件存不下来", running: false, tone: .error)
                }
            }
        }
    }

    /// 产物不再搬到 Application Support/成品目录：直接用 Python 临时目录里的原件。
    /// 下载成功后由 downloadDocx 删掉它；下载失败或取消面板时不删，还能再点一次下载。
    private func storeProduced(_ files: [URL]) -> URL? {
        return files.first
    }

    /// 点「下载 Word 试卷」：弹系统面板选位置
    func downloadDocx() {
        guard let src = docx.url else { return }
        let panel = NSSavePanel()
        panel.title = "保存 Word 试卷"
        panel.message = "选择试卷存到哪里"
        panel.nameFieldStringValue = defaultDocxName()
        if let t = UTType(filenameExtension: "docx") { panel.allowedContentTypes = [t] }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // 保存面板固定落在系统「下载」目录，不跟题目文件所在目录走。
        // 用户预期成品出现在"下载"里；跟着源文件走会让成品散落在各个素材文件夹中。
        // 注意：chooseFile（打开面板）仍然记着上次的目录，那是另一回事。
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
            // 只有真正下载成功才删临时原件：先删文件本身，再把同批的临时工作目录清掉
            // （目录名以“试卷识别-run-”开头、且确实在系统临时目录下才删，防止误删别处文件）。
            // 删完卡片回到未生成状态，同一个临时文件不会被重复下载第二次。
            try? fm.removeItem(at: src)
            let workDir = src.deletingLastPathComponent()
            if workDir.path.hasPrefix(NSTemporaryDirectory()),
               workDir.lastPathComponent.hasPrefix("试卷识别-run-") {
                try? fm.removeItem(at: workDir)
            }
            docx = .idle
            say("Word 试卷已保存 ✓", detail: dest.path, running: false, tone: .ok)
            revealInFinder(dest)
        } catch {
            say("保存失败", detail: error.localizedDescription, running: false, tone: .error)
        }
    }

    /// 在 Finder 里「打开所在文件夹并选中这个文件」。
    ///
    /// 不用 `activateFileViewerSelecting` —— 那个 API 会先激活 Finder 再开窗口，
    /// 用户反馈保存完批改稿后会额外弹一个"桌面"窗口（Finder 没有已开窗口时的默认行为）。
    /// `selectFile(_:inFileViewerRootedAtPath:)` 直接定位到目标文件夹，只开一个窗口。
    private func revealInFinder(_ file: URL) {
        let folder = file.deletingLastPathComponent().path
        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: folder)
    }

    private func defaultDocxName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "试卷-\(df.string(from: Date())).docx"
    }

    // MARK: - 开发用：登录流程自检

    /// `--logintest` 启动：强制成「未登录」→ 打开登录窗口 → 等真实探针发现已登录
    /// → 倒计时 → 强制隐藏。全程每秒打一行状态，用来验证注入的提示条和自动收起。
    /// 会真的把浏览器窗口弹出来几秒，只在开发时用。
    func runLoginSelfTest() {
        print("== 登录流程自检开始，等页面加载 ==")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self = self else { return }
            self.login = LoginStatus(kind: .loggedOut)
            self.loginSettled = true
            print("[t=0] 强制未登录，调用 openDeepSeek()")
            self.openDeepSeek()
            self.tickLoginTest(0)
        }
    }

    /// 开发用：读取当前 DeepSeek 输入区的模式探针结果，不改页面状态。
    /// `--modeprobe` 启动后等待页面加载，再把原始返回打印到标准输出并退出。
    func runModeProbe() {
        print("== 模式探针开始，等待页面加载 ==")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self = self else { exit(1) }
                let result = (try? self.js(Scripts.probeComposer)) ?? "(读取失败)"
                print("MODE_PROBE: \(result)")
                exit(0)
            }
        }
    }

    private func tickLoginTest(_ n: Int) {
        guard n <= 22 else {
            print("== 自检结束 ==")
            exit(0)
        }
        // evaluateSync 不能在主线程调用，先扔到后台读页面上的提示条文字
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let badge = (try? self.js(
                "(document.getElementById('__wb_badge__')||{}).textContent||'(无提示条)'"))
                ?? "(读取失败)"
            let line = String(
                format: "[t=%2ds] 倒计时=%d  alpha=%.1f  窗口在屏=%d  点击穿透=%d  登录态=%@  提示条=%@",
                n, self.loginCountdown, self.browser.windowAlpha,
                self.browser.isWindowOnScreen ? 1 : 0,
                self.browser.clickThrough ? 1 : 0,
                "\(self.login.kind)", badge)
            DispatchQueue.main.async {
                print(line)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.tickLoginTest(n + 1)
                }
            }
        }
    }

    // MARK: - 开发用：界面状态演示

    /// `--uidemo` 1=生成中 / 2=已出成品 / 3=失败
    /// 7=大批量图片（20 张，网格已撑满）/ 8=同 7，但处于「等待粘贴」态并弹一条超限提示
    /// 9=单张图片 + 直接打开大图预览
    /// 只为看视觉，不碰网络、不跑脚本。正式使用不会触发。
    func applyUIDemo(step: Int) {
        login = LoginStatus(kind: .loggedIn)
        loginSettled = true
        progress = ProgressInfo()

        func fillImages(_ count: Int) {
            uploads[.paper] = AppState.demoImages(count).enumerated().map {
                UploadItem(image: $1, name: "剪贴板图片\($0 + 1)")
            }
        }

        switch step {
        case 7:
            fillImages(20)
            pollingStopped = true
            return
        case 8:
            fillImages(20)
            pollingStopped = true
            pasteArmed = .paper
            showToast("最多 48 张图片，先移除一张再放", seconds: 8, slot: .paper)
            return
        case 9:
            fillImages(1)
            if let item = uploads[.paper]?.first { previewItem = item }
            pollingStopped = true
            return
        default:
            break
        }

        fillImages(12)
        if step == 1 {
            isRunning = true
            progress = ProgressInfo(
                title: "第 1 段写完了，正在请 AI 接着写第 2 段…",
                detail: "脚本比较长，AI 会分段写完，这是正常的",
                fraction: 0, running: true)
            docx = .building
        } else if step == 3 {
            isRunning = false
            progress = ProgressInfo(
                title: "生成失败了",
                detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
                fraction: 0, running: false, tone: .error)
            scriptOutput = "Traceback (most recent call last):\n  File \"生成试卷.py\", line 42\nKeyError: 'style'"
            docx = .failed("脚本报错（退出码 1）")
        } else {
            isRunning = false
            progress = ProgressInfo(
                title: "Word 试卷生成好了 ✓",
                detail: "在下面点「下载 Word 试卷」保存到电脑里",
                fraction: 1, running: false, tone: .ok)
            docx = .ready(URL(fileURLWithPath: "/tmp/试卷.docx"))
        }
    }

    /// 演示用：画几张「扫描件」样子的图，好让预览卡片里有真缩略图。
    /// 只有 `--uidemo7/8` 会用到。
    static func demoImages(_ count: Int) -> [NSImage] {
        (1...max(count, 1)).map { i in
            let size = NSSize(width: 520, height: 700)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            let border = NSBezierPath(rect: NSRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14))
            border.lineWidth = 2
            NSColor(calibratedWhite: 0.90, alpha: 1).setStroke()
            border.stroke()
            NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
            for row in 0..<9 {
                let w = size.width - 96 - CGFloat((row % 3) * 46)
                NSRect(x: 48, y: size.height - 130 - CGFloat(row) * 58, width: w, height: 11).fill()
            }
            ("扫描件 \(i)" as NSString).draw(
                at: NSPoint(x: 48, y: 44),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                                 .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)])
            image.unlockFocus()
            return image
        }
    }
}
