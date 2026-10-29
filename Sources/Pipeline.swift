import Foundation
import AppKit

private struct FilePayload {
    var url: URL
    var name: String
    var mime: String
}

extension AppState {

    /// 提示词（用户 2026-10-29 第 12 轮定的「简单版」，第 13 轮加手写作文分支，
    /// 第 23 轮由用户手改定稿）。
    ///
    /// **原则：只写规则 md 里没有的东西。**
    /// 排序依据、去重补全、去噪、绝对保真、字体版式、页面设置 —— 全在《试卷识别规则.md》里，
    /// 这里一个字都不重复，只说「按附件 1 办」。
    ///
    /// 提示词只负责五件事，都是 md 不可能知道的：
    /// 1. 这批附件分别是什么（文件名是动态的，md 不知道）
    /// 2. **先判断走哪条路**：印刷体试卷 → 按 md；学生手写作文 → 按下面 B 段（md 里没有）
    /// 3. 手写作文的转录规则（md 通篇讲试卷，一个字都没提手写）
    /// 4. Word 末尾那段「特别注意」—— 交付形态，md 不管
    /// 5. `# ===EXAM-END===` —— 程序判定代码写完的依据
    ///
    /// 第 23 轮改了四处（都是用户手改）：
    /// · 判据从 150 字长句拆成独立一块，用 · 列出来；原来「过半走 B」在一段里说了两遍
    /// · 加「按整批内容合起来判断，不要逐张、逐页单独判断」
    ///   —— 一篇手写作文拍 5 张，第 4 张只写两行时单张数不过半，整批会误判成情况 A
    /// · 「手写占全图文字」→「占全部文字的比例」—— 上传一整个 PDF 时「全图」不成立
    /// · 「特别提示」「代码结尾」合并成「收尾」三条，免得兜底被当成附加项跳过
    ///
    /// 以前这里复述了 70% 的 md 原文（排序、去重、去噪、保真、运行环境…），
    /// 用户 2026-10-29 明确要求砍掉：两边都在说同一件事，改一边就容易打架。
    static func promptText(paperNames: [String]) -> String {
        // 1–2 是两份规则（固定占位），图片从 3 开始编号
        let total = 2 + paperNames.count
        var lines: [String] = []
        lines.append("我发你 \(total) 个文件：")
        lines.append("")
        lines.append("1.《试卷识别规则.md》—— 规则说明，只读，不是待处理内容")
        lines.append("2.《学生手写文章转录规则.md》—— 规则说明，只读，不是待处理内容")

        if paperNames.isEmpty {
            lines.append("3.（没有试卷文件）")
        } else if paperNames.count == 1 {
            lines.append("3.\(Self.quoted(paperNames))—— 待处理的内容")
        } else {
            lines.append("3–\(total).\(Self.quoted(paperNames))—— 待处理的内容，共 \(paperNames.count) 张")
        }

        // 待处理内容的编号范围：单张就是「附件 3」，多张是「附件 3–N」。
        // 用户 2026-10-29 15:13 手改：原来这里先写一句「图片你直接看得见，不需要任何 OCR 库，
        // 也不用讨论怎么识别图片」—— 那句话等于把「我到底能不能识别图片」摆到模型面前，
        // 深度思考时它就会顺着这句自问自答。整段删掉，改成让它自己看一遍再判断。
        let range = paperNames.count == 1 ? "附件 3" : "附件 3–\(total)"

        lines.append("")
        lines.append("先把\(range) 全部看一遍，判断这批内容属于下面哪种情况，然后只走那一条路。")
        lines.append("")
        lines.append("""
        ━━ 怎么判断 ━━
        数手写字符占全部文字的比例 —— 一个英文字母算 1 个、一个中文字算 2 个；空格、空行、手机状态栏、软件界面栏、返回按钮、水印、页码都不算。
        · 手写超过一半 → 情况 B
        · 其余 → 情况 A
        按整批内容合起来判断，不要逐张、逐页单独判断。定了就直接走，不用再考虑另一条。
        """)
        lines.append("")
        lines.append("""
        ━━ 情况 A：印刷体试卷 ━━
        按附件 1 的规则，把这批内容转成一份完整的 Word 试卷。
        """)
        lines.append("")
        lines.append("""
        ━━ 情况 B：学生手写作文 ━━
        按附件 2 的规则，把这批内容转成一份学生手写文章转录合辑。
        """)
        lines.append("")
        lines.append("""
        ━━ 收尾 ━━
        1. Word 末尾可以选择性增加一段「特别注意」：先用一行「特别注意」作标题（蓝色 #0000FF、加粗、居中、三号字 16pt），再另起一段普通格式的蓝色文字，写清楚这次处理里哪些地方不够明确、可能模糊、或者有内容读不出来。没有需要提醒的就完全不写，连标题、空行都不要有。
        2. 如果你真的完全判断不了该走 A 还是 B，或者碰到规则里没写、完全不知道该怎么处理的情况 —— 也必须照常输出完整的 Python 代码（代码的作用是生成一份带有上面1.中提到的「特别注意」事项），不要只回一段文字、不要反问用户、不要空着不写。
        3. Python 代码的最后一行必须原样写上：
        # ===EXAM-END===
        这一行必须是代码框里的最后一行，它之后不能再有任何代码。这是用户判断代码是否输出完整的标记，务必保留、不要改动、不要省略。
        """)
        return lines.joined(separator: "\n")
    }

    /// `《a》、《b》、《c》`
    private static func quoted(_ names: [String]) -> String {
        names.map { "《\($0)》" }.joined(separator: "、")
    }

    /// AI 必须在代码末尾打上的结束标记
    static let endMarker = "# ===EXAM-END==="

    private var docxMime: String {
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    }

    private func mimeFor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "docx": return docxMime
        case "doc": return "application/msword"
        case "md": return "text/markdown"
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    /// 重名附件补序号：`page1.jpg` / `page1-2.jpg`。
    /// 两个原因：一是附件条上分不清谁是谁；二是 `checkNames` 用子串匹配，
    /// 重名会让两个文件互相顶掉（一个到了就当成都到了）。
    /// **只改送给网页的名字，磁盘上的文件一个字节都不动。**
    private func dedupeNames(_ items: [FilePayload]) -> [FilePayload] {
        var used = Set<String>()
        return items.map { item in
            var copy = item
            let ns = item.name as NSString
            let ext = ns.pathExtension
            let base = ns.deletingPathExtension
            var candidate = item.name
            var n = 2
            while used.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                n += 1
            }
            used.insert(candidate.lowercased())
            copy.name = candidate
            return copy
        }
    }

    // MARK: - 入口

    func runPipeline() {
        guard !isRunning else { return }
        isRunning = true
        stopRequested = false
        progressLines = []
        lastLogAt = nil          // 新一轮从零计时，别把上一轮的间隔带过来
        docx = .idle
        // 测试期：开跑就把日志摊开，跑的过程中能一直看着（正式版改成 false）
        if Self.autoOpenLogWhileTesting { openLog() }

        // 先把框里的文件拷到局部变量，再把上传框清空 —— 顺序反了就拿不到文件了。
        // 一个框里可能有很多张图（整份试卷），所以拷的是数组不是单个 URL。
        let paperFiles = items(for: .paper).compactMap { $0.url }
        let auto = autoSend
        submitAndClearUploads()

        say("正在识别试卷…",
            detail: "试卷已提交给 DeepSeek，上传框已清空以免重复生成。页数多的话要几分钟，请稍候。",
            running: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // 浏览器隐形时系统会做 App Nap 节流，压住它保证流式输出不卡
            let token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "等待 DeepSeek 识别试卷")
            defer { ProcessInfo.processInfo.endActivity(token) }

            var script: String?
            var failure: String?
            do {
                script = try self.pipeline(paperFiles: paperFiles, auto: auto)
            } catch {
                failure = error.localizedDescription
                self.log("✗ \(failure ?? "")")
            }
            DispatchQueue.main.async {
                self.isRunning = false
                if let failure = failure {
                    let aborted = failure.contains("已中止")
                    let friendly = aborted ? "已中止" : "生成失败了"
                    // 上传框是提交时清空的，失败/中止就把文件放回去，省得重新选
                    self.restoreHeldFiles()
                    self.say(friendly,
                             detail: aborted
                                ? "试卷没有生成，文件已放回上传框，可直接重试"
                                : failure,
                             running: false,
                             tone: aborted ? .idle : .error)
                    if !aborted {
                        self.docx = .failed(failure)
                    }
                    return
                }
                if let script = script, !script.isEmpty {
                    self.offerScript(script)
                } else if auto {
                    self.restoreHeldFiles()
                    self.say("AI 回答完了，但没找到脚本",
                             detail: "文件已放回上传框，可以再试一次",
                             running: false, tone: .error)
                }
            }
        }
    }

    // MARK: - 主流程

    @discardableResult
    private func pipeline(paperFiles: [URL], auto: Bool) throws -> String? {
        guard !paperFiles.isEmpty else {
            throw BridgeError.failed("还没放试卷文件")
        }
        guard let ruleURL = AppState.bundledRule else {
            throw BridgeError.failed("App 内置的规则文件丢了，请重新安装 App")
        }
        guard let handRuleURL = AppState.bundledHandwritingRule else {
            throw BridgeError.failed("App 内置的手写转录规则丢了，请重新安装 App")
        }

        // 两份规则固定打头（附件 1 = 试卷规则、附件 2 = 手写规则），后面依次是待处理的每一页。
        // 顺序必须和 `promptText` 里的编号一致：1、2 是规则，图片从 3 开始。
        var uploads = [
            FilePayload(url: ruleURL, name: "试卷识别规则.md", mime: "text/markdown"),
            FilePayload(url: handRuleURL, name: "学生手写文章转录规则.md", mime: "text/markdown"),
        ]
        uploads += paperFiles.map { FilePayload(url: $0, name: $0.lastPathComponent, mime: mimeFor($0)) }
        // 不同目录下的同名文件（比如两张都叫「IMG_0001.jpg」）在附件条里分不清，
        // 而且 checkNames 是按子串匹配的，重名会互相顶掉 —— 重名时补个序号。
        uploads = dedupeNames(uploads)

        // 提示词里的名字用**去重之后**的，跟附件条上显示的一致。前两个固定是规则。
        let paperNames = uploads.dropFirst(2).map { $0.name }
        var prompt = AppState.promptText(paperNames: paperNames)

        // 0. 开新对话。三档，从最省事往下退：
        //
        //   ① 页面已经停在根地址 → 什么都不做。App 第一次打开、刚登录、上一轮没发出去，
        //      都落在这里 —— 本来就是空对话，按 ⌘J 或重载都是多余的。
        //   ② 停在会话页（/a/chat/s/<id>）→ 按 ⌘J。它只切 SPA 里的会话，不重载页面，
        //      比 reload 快 2~4 秒，也不用重新等整页渲染。走真实 NSEvent 注入，
        //      和「继续生成」是同一条路（见 BrowserController.sendCommandKey）。
        //   ③ ⌘J 按了没反应 / 页面没加载完 → 重载根地址。
        //
        // 以前这里是无条件重载根地址，因为「点页面上的『开启新对话』按钮」从 v0.12 到
        // v0.20 一次都没点中过（选择器永远是 NOT_FOUND）。重载那条路留着当兜底：
        // 绝不能在旧对话里继续提问，否则上一轮的上下文会污染这一轮的识别。
        say("正在准备新对话…", detail: "重置页面中，稍等几秒", running: true)

        switch browser.newChatByShortcut() {
        case .alreadyFresh:
            // App 刚启动、刚登录、上一轮没发出去 —— 页面就停在根地址，本来就是空对话。
            // 这里**什么都不做**，别按 ⌘J 也别重载。
            log("页面已在根地址，本来就是新对话，跳过重置")
        case .shortcut(let seconds):
            log("⌘J 开新对话：\(String(format: "%.1f", seconds)) 秒")
            // 地址栏变了不代表 DOM 已经换完（SPA 切会话是异步渲染）。
            // 稍等一下再往里塞附件，免得塞进上一轮那个还没拆掉的输入框。
            Thread.sleep(forTimeInterval: 1.2)
        case .failed:
            log("⌘J 没换掉会话，回退重载根地址")
            // loadDeepSeek 里有 NSWindow 操作，必须回主线程。但它是异步的，
            // 等它跑起来再轮询标志的话，读到的是上一轮的 true —— 循环立刻退出，
            // 日志里就是「用时 0.0 秒」，等于没等。所以先把标志同步打回 false 再派发。
            browser.markReloading()
            DispatchQueue.main.async { [weak self] in self?.browser.loadDeepSeek(force: true) }
            var waited = 0.0
            while !browser.isPageLoaded && waited < 25 {
                Thread.sleep(forTimeInterval: 0.25)
                waited += 0.25
            }
            log("页面重载：\(String(format: "%.1f", waited)) 秒")
            if !browser.isPageLoaded {
                log("⚠️ 25 秒内没等到页面加载完成，继续尝试（后面探针会暴露真实状态）")
            }
        }

        // didFinish 只说明文档到了，SPA 还没渲染完。以前是固定睡 2 秒赌一把，
        // 现在直接等输入框真的出现 —— 快的时候几百毫秒就过，慢的时候也不会白等。
        var ready = 0.0
        while ready < 10 {
            let p = (try? self.js(Scripts.probeComposer)) ?? ""
            if p.contains("\"textarea\":true") { break }
            Thread.sleep(forTimeInterval: 0.4)
            ready += 0.4
        }
        if ready > 0 { log("等输入框出现：\(String(format: "%.1f", ready)) 秒") }

        // 1. 探针：确认输入框和文件框的结构
        // 注：深度思考+智能搜索已在登录成功时由 ensureDeepSeekModes() 处理，
        // 这里只探结构，不再重复检测开关状态。
        let probe = try self.js(Scripts.probeComposer)
        log("页面：\(probe)")

        // 2. 清空分片缓冲
        _ = try self.js(Scripts.resetBuffer)

        // 3. 把字节灌进页面
        var totalBytes = 0
        for (index, item) in uploads.enumerated() {
            try checkStop()
            let data = try Data(contentsOf: item.url)
            totalBytes += data.count
            try feed(index: index, data: data)
            log("载入 \(item.name)（\(data.count / 1024) KB）")
            say("正在上传文件…",
                detail: "\(item.name)（第 \(index + 1)/\(uploads.count) 个）",
                fraction: Double(index + 1) / Double(uploads.count + 2),
                running: true)
        }

        // 4. 组装成 File 并交给页面
        let defs = uploads.enumerated().map { index, item -> [String: Any] in
            ["idx": index, "name": item.name, "type": item.mime]
        }
        let injected = try self.js(Scripts.commitFiles(defsJSON: jsonString(defs)))
        // 形如 INPUT:5/0 —— 前面是交给网页的个数，后面是事件处理完还剩几个。
        // 后一个数常见是 0：网页接手后会把 input 清空，属正常，别当成注入失败。
        log("注入：\(injected)")
        say("正在把试卷交给 AI…",
            detail: "一共 \(uploads.count) 个文件：规则 2 个、试卷 \(paperFiles.count) 个",
            fraction: 0.55, running: true)

        // 4. 等附件条渲染出来。
        // 等待时间按体积给：整份试卷几十张照片能到上百 MB，固定 25 秒根本不够。
        let waitSeconds = min(300, max(25, 20 + Double(totalBytes) / 1_000_000 * 3.0))
        var missing = try waitFor(expected(uploads), timeout: waitSeconds)
        log(missing.isEmpty
            ? "\(uploads.count) 个附件已就位（\(Int(totalBytes / 1024)) KB）"
            : "还没出现：\(missing.joined(separator: "、"))")

        // 4.1 .md 被拒收就改 .txt 重试，并同步替换提示词里的文件名
        //
        // 规则是**两份** md（第 13 轮加了《学生手写文章转录规则.md》），所以必须逐个补传。
        // 原来只写死了第一份：真碰上 DeepSeek 不收 .md 时，第二份会留在 missing 里，
        // 补完第一份照样抛「这些文件没能放进对话框」—— 补了个寂寞。
        for index in 0..<2 where missing.contains(uploads[index].name) {
            let oldName = uploads[index].name
            let newName = (oldName as NSString).deletingPathExtension + ".txt"
            log("DeepSeek 不收 .md，\(oldName) 改用 .txt 重试")
            say("正在换一种格式重传规则文件…", fraction: 0.6, running: true)
            uploads[index].name = newName
            uploads[index].mime = "text/plain"
            prompt = prompt.replacingOccurrences(of: "《\(oldName)》", with: "《\(newName)》")

            let retry: [[String: Any]] = [
                ["idx": index, "name": newName, "type": "text/plain"]
            ]
            _ = try self.js(Scripts.commitFiles(defsJSON: jsonString(retry)))
            let still = try waitFor([(name: newName, isImage: false)], timeout: 20)
            if !still.isEmpty {
                throw BridgeError.failed("规则文件传不上去，DeepSeek 可能既不收 .md 也不收 .txt")
            }
            missing.removeAll { $0 == oldName }
        }

        if !missing.isEmpty {
            throw BridgeError.failed("这些文件没能放进对话框：\(missing.joined(separator: "、"))")
        }
        say("文件都传上去了", detail: "正在把识别要求发给 AI", fraction: 0.68, running: true)

        // 5. 先清空输入框，再填提示词。
        // 网页版收到附件后会把文件名当文字塞进输入框（截图见 HANDOVER §6.9），
        // 不清的话提示词前面会挂着「IMG_3435.jpeg 未标题-1.png」这一串。
        // 顺序必须是「先等附件就位 → 再清 → 再填」：清早了网页还会补回来。
        _ = try fillPrompt(prompt)

        // 6. 发送
        if auto {
            try checkStop()
            for second in stride(from: 4, through: 1, by: -1) {
                say("马上开始生成…", detail: "\(second) 秒后自动发送，不用你操作",
                    fraction: 0.75, running: true)
                Thread.sleep(forTimeInterval: 1.0)
            }
            // 发送前再确认一次：万一这几秒里网页又把文件名补进输入框，重填一遍。
            // 只做回读比对，一致就不动输入框（无谓地清空重填反而多一次竞态）。
            if try self.js(Scripts.readText).trimmingCharacters(in: .whitespacesAndNewlines)
                != prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                log("发送前回读不一致，重填提示词")
                _ = try fillPrompt(prompt)
            }
            let sent = try self.js(Scripts.sendNow)
            log("发送结果：\(sent)")
            if sent == "NO_TARGET" {
                throw BridgeError.failed("找不到发送按钮")
            }
            say("已经发给 AI 了", detail: "AI 正在读题目，通常要 1–3 分钟，请勿关闭", running: true)
            // 7. 等它写完，中途需要就点「继续」
            return try waitForReply()
        } else {
            say("已经填好了，请在窗口里按回车发送", running: false)
            return nil
        }
    }

    /// 清空输入框 → 填入提示词 → 回读校验。对不上就再来一次（最多两次）。
    /// 回读这一步是关键：网页插入文件名是异步的，只靠「填完就当成功」会漏。
    /// 返回 true 表示回读与提示词完全一致。
    @discardableResult
    private func fillPrompt(_ prompt: String) throws -> Bool {
        for attempt in 1...2 {
            _ = try self.js(Scripts.clearText)
            // 清完稍等一下，让网页那边的 React 状态落定，否则它可能把我们填的又盖掉
            Thread.sleep(forTimeInterval: attempt == 1 ? 0.35 : 0.8)

            let filled = try self.js(Scripts.fillText(textJSON: jsonString(prompt)))
            guard filled.hasPrefix("OK") else {
                throw BridgeError.failed("文字填不进去：\(filled)")
            }

            let back = try self.js(Scripts.readText)
            if sameText(back, prompt) {
                log("提示词已填入并回读一致（\(prompt.count) 字）")
                return true
            }
            log("第 \(attempt) 次填入后回读不一致：输入框 \(back.count) 字 / 应为 \(prompt.count) 字，清空重填")
        }
        // 两次都对不上就不再硬失败 —— 内容已经在框里，多出来的无非是文件名，AI 自己能认出来
        log("⚠️ 提示词回读仍不一致，按当前内容发送")
        say("提示词已填入", detail: "输入框内容和预期略有出入，仍按此发送", fraction: 0.7, running: true)
        return false
    }

    /// 回读比对用的相等判断。只忽略首尾空白 —— 输入框偶尔会多一个尾随换行，
    /// 那不是问题，不该为它触发一次重填。
    private func sameText(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 等回复 / 抓代码

    /// 等 AI 写完的总上限（秒）。**全 App 只有这一处定义**，改时长只改这里。
    /// 用户 2026-10-26 定：这个规模 10 分钟就是上限，一到就判失败，不再顺延。
    /// 上一版把总上限放到 30 分钟，结果一次成功跑了 15 分钟，太长了。
    private static let replyDeadline: TimeInterval = 600

    /// 轮询回复区，直到内容不再变化；期间自动点「继续」
    /// 注意：点了不算数，必须验证页面内容真的涨了，否则记一次无效
    private func waitForReply() throws -> String? {
        // 以前签名上挂了个 `timeout: TimeInterval = 240` 的参数，但函数体压根不读它
        // （直接写死 600），谁想改时长都会白改。2026-10-27 删掉，只留 replyDeadline。
        let deadline = Date().addingTimeInterval(Self.replyDeadline)
        // 发送后先给页面一点时间开始动
        Thread.sleep(forTimeInterval: 3.0)

        var lastTextLen = -1
        var lastCodeLen = -1
        var stableRounds = 0
        var clicksTried = 0
        var clicksIneffective = 0
        var lastStageKey = ""
        var loggedMain = false
        var endMarkSeen = false
        var lastChangeAt = Date()
        var lastThinkBlocks = -1

        func announce(_ key: String, _ title: String, _ detail: String = "") {
            guard key != lastStageKey else { return }
            lastStageKey = key
            say(title, detail: detail, running: true)
        }

        while Date() < deadline {
            if stopRequested {
                throw BridgeError.failed("已中止")
            }

            let raw = try self.js(Scripts.replyState)
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Thread.sleep(forTimeInterval: 2.0)
                continue
            }
            let generating = obj["generating"] as? Bool ?? false
            let hasContinue = obj["hasContinue"] as? Bool ?? false
            let blocks = obj["blocks"] as? Int ?? 0
            let pres = obj["pres"] as? Int ?? 0
            let codes = obj["codes"] as? Int ?? 0
            let codeLen = obj["codeLen"] as? Int ?? 0
            let textLen = obj["textLen"] as? Int ?? 0
            let hasSaveTail = obj["hasSaveTail"] as? Bool ?? false
            let hasEndMark = obj["hasEndMark"] as? Bool ?? false
            let looksComplete = obj["looksComplete"] as? Bool ?? false
            let afterLines = obj["afterLines"] as? Int ?? 0

            // 思考区被跳过了几个代码块。为 0 说明这一轮没走深度思考（或者类名变了 ——
            // 后者要警惕：类名一改，「跳过思考区」就失效，会退回 2026-10-29 那个抓错脚本的坑）。
            let thinkBlocks = obj["thinkBlocks"] as? Int ?? 0
            if thinkBlocks != lastThinkBlocks {
                lastThinkBlocks = thinkBlocks
                if thinkBlocks > 0 {
                    log("思考区里也有 \(thinkBlocks) 个代码块，已忽略（只认回答区的）")
                }
            }

            if textLen != lastTextLen || codeLen != lastCodeLen {
                lastChangeAt = Date()
                // 总上限就是 10 分钟：增长只影响“正在输出”的判断，不再延长总时间。
            }

            // 结束标记随时判定：即使 generating 还报 true（停止按钮残留 / 纯图标没认出来），
            // 只要标记在，就说明代码本身写完了，不用等到“没在生成”才认。
            //
            // 2026-10-29 用户定：**看到标记只等 3 秒，不要乘 2**。
            // 以前是「连续两轮都在」，而轮间隔受页面变化影响，实测白等 6 秒。
            // 现在固定成：第一次看到 → 睡 3 秒 → 再看一眼还在就收工。
            if hasEndMark {
                if !endMarkSeen {
                    endMarkSeen = true
                    log("看到结束标记 # ===EXAM-END===，等 3 秒确认")
                    Thread.sleep(forTimeInterval: 3.0)
                    continue
                }
                log("结束标记仍在，判定写完")
                say("脚本写完了", detail: "正在把它取回来…", running: true)
                return try grabScript()
            } else {
                endMarkSeen = false
            }

            // —— 统一播报（用户要求）：内部每轮判断增长，但状态框每轮只报下面这一句，持续不断。
            // 不再有“正在写 / 正在读 / 快写完了”几套文案，也不再另起多套节奏。
            // 字数涨没涨，一看这句里的数字就知道；分段提示在下面点“继续”时会立刻报一次，
            // 下一轮播报（5 秒后）再接上这句，不会立刻盖掉分段提示。
            // 还没出现真的代码框、字数还是 0 时，别报“代码目前 0 字”，看着着急。
            // 先报思考中，直到代码框出现且字数大于 0，才恢复原来的代码字数播报。
            if blocks > 0 && codeLen > 0 {
                say("AI 正在思考…", detail: "代码目前 \(codeLen) 字，正在等它继续输出", running: true)
            } else {
                say("DeepSeek 正在认真思考", detail: "代码即将呈现", running: true)
            }
            if hasContinue {
                announce("continue-\(clicksTried)",
                         clicksTried == 0
                            ? "第 1 段写完了，正在请 AI 接着写第 2 段…"
                            : "第 \(clicksTried + 1) 段写完了，正在请 AI 接着往下写…",
                         "脚本比较长，AI 会分段写完，这是正常的")
            }

            if looksComplete && !loggedMain {
                loggedMain = true
                let which = hasSaveTail ? "末尾有 .save( 调用" : "末尾有 main() 收尾"
                log("代码出现收尾标志：\(which)")
            }

            // 还在流式输出 → 继续等，轮询步长统一为 5 秒（状态框播报也按这个步长来）
            if generating {
                stableRounds = 0
                clicksIneffective = 0
                lastTextLen = textLen
                lastCodeLen = codeLen
                Thread.sleep(forTimeInterval: 5.0)
                continue
            }

            // 被截断了 → 点继续，然后验证
            if hasContinue {
                stableRounds = 0

                // ⚠️ 2026-10-29 实测踩到的坑：文字还在长，说明其实正在生成，
                // 但「继续生成」按钮可能仍挂在 DOM 上（停止按钮是纯图标，generating 认不出来），
                // 这时点下去会落到同一位置的「停止」上，把刚恢复的生成掐死。
                // 日志证据：点完继续 1.6 秒后又点了一次 → 之后 24 秒一个字没涨 → 失败。
                // 所以：最近 4 秒内还在涨字，就绝不点，老老实实等它写完。
                if Date().timeIntervalSince(lastChangeAt) < 4.0 {
                    lastTextLen = textLen
                    lastCodeLen = codeLen
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

                if clicksIneffective >= 2 {
                    throw BridgeError.failed(
                        "AI 停下来之后没有继续写。可能到了长度上限，请再试一次。")
                }
                if clicksTried >= 5 {
                    throw BridgeError.failed("已经连续催了 5 次，AI 还是没有继续写，请再试一次。")
                }

                let before = textLen
                let r = try self.clickContinueButton()
                clicksTried += 1

                if r.hasPrefix("REAL_MOUSE") || r.hasPrefix("CLICKED:") {
                    log("点「继续」第 \(clicksTried) 次 → \(r)")

                    // 【2026-10-29】判据换了：不看「12 秒内有没有涨字」，看「按钮有没有消失」。
                    //
                    // 用户实测：手点下去按钮**瞬间消失**，绝不会变成「停止」。
                    // 日志证据：有一次点了正好 12.0 秒才出字（卡在 6 次轮询的边界上），
                    // 再慢半秒就会被判成无效、多点一次 —— 而多点会把生成掐死（上次的坑）。
                    // 点击被接受 ≠ 立刻出字，AI 点完「继续」要先重新想十几秒。
                    //
                    // probeY：只认刚点的那个位置，别把历史消息残留的旧按钮算进来。
                    let probeY = self.clickedY(from: r)
                    var buttonGone = false
                    for _ in 0..<3 {
                        Thread.sleep(forTimeInterval: 0.2)
                        if let gone = try? self.continueButtonGone(nearY: probeY), gone {
                            buttonGone = true
                            break
                        }
                    }

                    if buttonGone {
                        log("按钮已消失，点击被页面接受")
                        // 点击成功后就安心等它出字。实测最长 12 秒以上，这里给 24 秒。
                        //
                        // ⚠️ 不能干等满 24 秒：AI 有时只写两三百字就又截断，
                        // 「继续」按钮几秒内会重新出现。死等只会白耗时间，
                        // 所以 6 秒后开始顺带盯按钮，一冒出来就提前交回外层循环再点。
                        var grew = false
                        for attempt in 0..<12 {
                            Thread.sleep(forTimeInterval: 2.0)
                            if let now = try? self.textLength(), now > before {
                                grew = true
                                log("继续生效（约 \(2 * (attempt + 1)) 秒后开始出字，涨了 \(now - before) 字）")
                                break
                            }
                            if attempt >= 2, let back = try? self.continueButtonGone(nearY: probeY), !back {
                                log("按钮又出现了（等了 \(2 * (attempt + 1)) 秒没出字），AI 又停住了，交给下一轮再催")
                                break
                            }
                        }
                        if grew {
                            clicksIneffective = 0
                            lastChangeAt = Date()
                            // 分段开始必须在状态框里留一句：第 1 段是原生的，第 1 次点“继续”就是第 2 段开始。
                            // 自动点“继续”本身不动（用户要求），一般最多 3 段、点两次，5 次上限只是兜底，不改。
                            // 点完后下一轮就是 5 秒播报重新开始，直到结束。
                            say("第 \(clicksTried + 1) 段开始生成", detail: "代码目前 \(codeLen) 字，正在等它继续输出",
                                running: true)
                        } else {
                            // 按钮消失了却没出字：点击是有效的，只是 AI 还在想。
                            // 绝不能重复点击（会掐死生成），交给外层循环和 10 分钟总超时兜底。
                            log("按钮已消失但 24 秒未见新内容，继续等，不重复点击")
                        }
                    } else {
                        // 按钮还在 = 这次点击被吞了（窗口刚激活 / 页面没有 hover 状态）。
                        // 立刻补一次，不用干等 12 秒。
                        clicksIneffective += 1
                        log("点了 0.6 秒按钮仍在，这次点击被吞了（无效 \(clicksIneffective)/2）")
                    }
                } else {
                    clicksIneffective += 1
                    log("点「继续」失败：\(r)")
                }

                lastTextLen = textLen
                lastCodeLen = codeLen
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }

            // 【主判定】语义信号：脚本出现收尾标志，且代码块后面还有说明文字
            // （结束标记的判定已移到循环顶部，随时都做，这里不再重复计数。）
            if blocks > 0 && looksComplete && afterLines >= 3 {
                log("脚本收尾 + \(afterLines) 行说明，判定写完")
                say("脚本写完了", detail: "正在把它取回来…", running: true)
                return try grabScript()
            }

            // 【兜底判定】2026-10-25 的教训：旧代码“稳定 10 秒就按完成处理”，
            // 深度思考的思考间隙很容易超过 10 秒，结果抓到写了一半、字符串都没闭合的
            // 截断脚本（16216 字，第 368 行 SyntaxError），然后 Python 报错收场。
            //
            // 2026-10-27 用户定：**不必等 60 秒**。理由是到目前为止结束标志从未失手，
            // 60 秒纯属白等。改成「一轮没长 + 有收尾标志」就收工（循环 3 秒一轮，即约 3 秒）。
            // 仍保留两条底线：① 没有收尾标志时绝不执行，继续等；② 总上限 10 分钟不变。
            if blocks > 0 {
                if textLen == lastTextLen && codeLen == lastCodeLen {
                    stableRounds += 1
                    if looksComplete && stableRounds >= 1 {
                        log("内容 3 秒未变且有收尾标志，按完成处理")
                        say("脚本看起来写完了", detail: "正在把它取回来…", running: true)
                        return try grabScript()
                    }
                    // 没有收尾标志：攒够 60 秒（20 轮 × 3 秒）提示一次，然后继续等
                    if stableRounds >= 20 {
                        log("内容稳定 60 秒但未见收尾标志，继续等，不擅自执行截断脚本")
                        stableRounds = 0
                    }
                } else {
                    stableRounds = 0
                }
            } else {
                // 没有代码块：深度思考先想后写，75 秒太短，放到 180 秒再判“没给脚本”
                let idle = Date().timeIntervalSince(lastChangeAt)
                if idle > 180 {
                    throw BridgeError.failed(
                        "页面停住了，但没找到脚本（pre=\(pres) code=\(codes) 字数=\(textLen)）。"
                        + "可能是 AI 没有输出脚本。")
                }
                stableRounds = 0
            }

            // 思考提示已统一移到循环顶部，每轮报一次，这里不再另起一套节奏。
            lastTextLen = textLen
            lastCodeLen = codeLen
            // 3 秒一轮（原来是 5 秒）：兜底判定要「一轮没长」≈3 秒就收工，
            // 轮间隔必须跟着缩，否则「3 秒」实际是 5 秒。轮数阈值也按 3 秒重算过。
            Thread.sleep(forTimeInterval: 3.0)
        }

        throw BridgeError.failed("等了 10 分钟仍未等到完整回答（没有结束标记、也没有收尾标志），没有擅自执行截断的脚本，请再试一次。")
    }

    /// 单独读一次正文长度，用于验证「继续」是否真的生效
    /// 必须用 textContent —— innerText 依赖布局，页面被判隐藏时会失真
    private func textLength() throws -> Int {
        let raw = try self.js("(document.body.textContent||'').length")
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 点「继续生成」
    /// 内置浏览器走真实 NSEvent 注入（isTrusted = true），Safari 只能走 JS。
    ///
    /// 2026-10-29 加了两道保险（用户实测：手点 0.1–0.2 秒就继续、按钮瞬间消失）：
    /// ① 坐标只在按钮**已经在视口内**时才取，需要滚动就先返回 SCROLLING 等滚完再取；
    /// ② 点之前做 `elementFromPoint` 命中测试，命中元素不是按钮就绝不下手。
    private func clickContinueButton() throws -> String {
        var lastRaw = "NOT_TRIED"

        for attempt in 0..<4 {
            let raw = try self.js(Scripts.locateContinue)
            lastRaw = raw

            // 页面刚滚动过，坐标还不作数 —— 等它停稳再取一次
            if raw == "SCROLLING" {
                log("「继续」按钮不在视口内，滚动后重新取坐标（\(attempt + 1)/4）")
                Thread.sleep(forTimeInterval: 0.45)
                continue
            }

            // 按钮被别的东西盖住 / 正在淡出 —— 等一下再看，不算一次失败
            if raw.hasPrefix("NOT_HIT") {
                log("「继续」按钮命中测试未通过（\(raw)），\(attempt < 3 ? "稍后重试" : "放弃")")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
                continue
            }

            if raw == "NOT_FOUND" { return "NOT_FOUND" }
            if raw == "ZERO_SIZE" { return "ZERO_SIZE" }

            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let x = obj["x"] as? Double,
                  let y = obj["y"] as? Double else {
                return "BAD_LOCATE:\(raw.prefix(60))"
            }

            if engine == .webview {
                var ok = false
                DispatchQueue.main.sync {
                    ok = self.browser.clickAtViewportPoint(x: CGFloat(x), y: CGFloat(y))
                }
                if ok {
                    return String(format: "REAL_MOUSE(%.0f,%.0f)", x, y)
                }
                let js = try self.js(Scripts.clickContinue)
                return "FALLBACK_JS:\(js.prefix(80))"
            }

            let js = try self.js(Scripts.clickContinue)
            return "SAFARI_JS:\(js.prefix(120))"
        }

        return "LOCATE_UNSTABLE:\(lastRaw.prefix(60))"
    }

    /// 「继续」按钮还在不在（只探测，不滚动、不点击、无副作用）
    ///
    /// `nearY` 是刚才点击时的视口 y。只检查这个位置附近的按钮，
    /// 避免历史消息里残留的旧「继续生成」被当成「按钮还在」。
    private func continueButtonGone(nearY: Double?) throws -> Bool {
        let raw = try self.js(Scripts.probeContinue(nearY: nearY))
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "NO"
    }

    /// 从 `REAL_MOUSE(123,456)` 里取出点击时的 y 坐标
    private func clickedY(from result: String) -> Double? {
        let prefix = "REAL_MOUSE("
        guard result.hasPrefix(prefix) else { return nil }
        guard let close = result.firstIndex(of: ")") else { return nil }
        let inner = result[result.index(result.startIndex, offsetBy: prefix.count)..<close]
        let parts = inner.split(separator: ",")
        guard parts.count == 2, let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return y
    }

    /// 把页面上的代码块取回来，挑出最像「生成试卷」的那段
    func grabScript() throws -> String? {
        // 0. 先看 AI 有没有自己说「看不到图片」。
        // ⚠️ 2026-10-29 复盘：这句话**不能当成事实**。14:29 那轮的思考流里它一边说
        // 「我无法真实地看到图片」，一边写出了原卷里的「复旦附中」标题和 Lhende Khola 洪水那篇
        // —— 它其实看见了，只是深度思考时习惯性自我怀疑（先套「我没有视觉」的常识，再被自己纠正）。
        // 所以这条只当**安全网**：命中就停下问一句，不擅自把内容当成品交出去。
        // 真要判断有没有看见，看草稿里有没有原卷的专有名词，比看这句话可靠。
        let answer = (try? self.js(Scripts.answerText)) ?? ""
        if let phrase = Self.blindHint(in: answer) {
            log("⛔️ AI 的回答里出现「\(phrase)」，无法确认它是否真看到了图片，先不执行")
            throw BridgeError.failed(
                "AI 的回答里出现了「\(phrase)」，没法确认它是否真的看到了图片。"
                + "为免把编出来的内容当成成品，这次先停下不执行。"
                + "如果图片确实已经传上去了，直接重跑一次即可。")
        }

        let lenRaw = try self.js(Scripts.grabBlocksBuild)
        guard let total = Int(lenRaw.trimmingCharacters(in: .whitespacesAndNewlines)),
              total > 0 else {
            log("页面上没有找到代码块")
            return nil
        }

        var encoded = ""
        encoded.reserveCapacity(total)
        let step = 40000
        var index = 0
        while index < total {
            let end = min(index + step, total)
            encoded += try self.js(Scripts.grabBlocksChunk(from: index, to: end))
            index = end
        }

        guard let json = encoded.removingPercentEncoding,
              let data = json.data(using: .utf8),
              let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              !blocks.isEmpty else {
            log("代码块解码失败")
            return nil
        }
        log("抓到 \(blocks.count) 个代码块，原文总长 \(blocks.reduce(0) { $0 + $1.count }) 字符")

        let joined = blocks.map { "```python\n\($0)\n```" }.joined(separator: "\n\n")
        return ScriptExtractor.extract(from: joined)
    }

    // MARK: - 工具

    /// AI 自曝「没看见图」的说法。只认明确指向图片的那几种，
    /// 不误伤「第 3 页字迹看不清」这类正常的「特别注意」。
    private static func blindHint(in text: String) -> String? {
        let pattern = "(看不到|看不见|无法[^。\\n]{0,6}(看到|查看|读取|识别)"
            + "|没有[^。\\n]{0,6}(看到|收到)|收不到)[^。\\n]{0,6}图片"
        guard let hit = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[hit])
    }

    /// 用户点了「中止」就在下一个检查点退出
    private func checkStop() throws {
        if stopRequested { throw BridgeError.failed("已中止") }
    }

    private func feed(index: Int, data: Data) throws {
        let base64 = data.base64EncodedString()
        let step = 96000
        var cursor = base64.startIndex
        while cursor < base64.endIndex {
            let end = base64.index(cursor, offsetBy: step, limitedBy: base64.endIndex)
                ?? base64.endIndex
            let chunk = String(base64[cursor..<end])
            _ = try self.js(Scripts.appendChunk(index: index, chunk: chunk))
            cursor = end
        }
    }

    /// 把附件清单翻译成探针要的形状：名字 + 是不是图片
    private func expected(_ items: [FilePayload]) -> [(name: String, isImage: Bool)] {
        items.map { (name: $0.name, isImage: $0.mime.hasPrefix("image/")) }
    }

    private func waitFor(_ files: [(name: String, isImage: Bool)],
                         timeout: TimeInterval) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        let payload = jsonString(files.map { ["n": $0.name, "i": $0.isImage ? 1 : 0] })
        var missing = files.map { $0.name }
        while Date() < deadline {
            if stopRequested { throw BridgeError.failed("已中止") }
            let raw = try self.js(Scripts.checkNames(filesJSON: payload))
            if let data = raw.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let list = obj["missing"] as? [String] {
                missing = list
                if list.isEmpty { return [] }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return missing
    }

    private func jsonString(_ obj: Any) -> String {
        // fragmentsAllowed 才能序列化顶层的字符串，否则传 String 会抛异常把 App 打死
        guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}
