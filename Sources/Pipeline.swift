import Foundation
import AppKit

private struct FilePayload {
    var url: URL
    var name: String
    var mime: String
}

extension AppState {

    /// 提示词。**文件名和角色按实际附件拼，不写死**。
    ///
    /// 只有一份输入（整份试卷），但可能是 20 张图片，也可能是 1 个 PDF。
    /// 顺序由代码如实报给 AI，剩下的排序、去重叠交给它按规则做 —— 代码不知道
    /// 哪张图是第几页，硬排反而会误导。
    static func promptText(paperNames: [String]) -> String {
        let total = 1 + paperNames.count
        var lines: [String] = []
        lines.append("我发你 \(total) 个文件，用途如下：")
        lines.append("1.《试卷识别规则.md》—— 识别与排版规则，一切以它为准")

        if paperNames.isEmpty {
            lines.append("2.（没有试卷文件）")
        } else if paperNames.count == 1 {
            lines.append("2.\(Self.quoted(paperNames))—— 试卷本体（整份试卷）")
        } else {
            lines.append("2–\(total).\(Self.quoted(paperNames))—— 试卷本体，共 \(paperNames.count) 张，"
                         + "属于**同一份试卷**，请当成一份来排")
        }

        lines.append("")
        lines.append("""
        这些文件的先后是我上传的顺序，**不等于卷面顺序**：拍照、截图、导出时很容易乱，相邻两张还可能有重叠，也可能断页。请按下面的方式处理：

        1. **排序**：先看卷面的大标题结构（罗马数字 I、II、III，中文数字 一、二、三，阿拉伯数字 1. 2. 3. 等）判断每张图属于哪一部分，再结合上下文语义排出正确顺序（例如 听力 → 语法 → 阅读 → 写作）。
        2. **去重与补全**：识别相邻图片的重叠部分，同一道题、同一段文字在 Word 里只出现一次；断页缺了极小一段时，用语义补齐。
        3. **去噪**：忽略水印、手机或平板的状态栏、返回按钮、小红书号等与卷面无关的界面元素。
        4. **绝对保真**：除上述界面元素外，卷面上的文字一律逐字逐句完整提取，包括解析、范文、同一道题的多个答案版本，不得概括、省略、改写，也不得为了排版好看而删减。

        读完所有文件后，按《试卷识别规则.md》把它排成一份完整的 Word 试卷。因为现在是网页版无法输出文件，请你给出完整的 Python 脚本，我会自动执行；规则没写到的地方，按「尽量接近原图」处理。

        补充说明（我的运行环境）：Python 3.12，只装了 python-docx（及其依赖 lxml），没有 pandas、matplotlib、openpyxl、Pillow 之类，请不要 import；脚本要能一次跑完，不要用 input() 等待键盘输入；最后用 save() 把成品存成 .docx，文件名用中文、能看出是哪份试卷。

        【格式要求，非常重要】Python 代码的最后一行必须原样写上这一行注释：
        # ===EXAM-END===
        这一行必须是代码框里的最后一行，它之后不能再有任何代码。这是我用来判断代码是否输出完整的标记，请务必保留、不要改动、不要省略。

        【收尾说明，同样重要】代码块结束之后，请再写一段简短的中文说明，至少 3 行，讲清楚：这份 Word 试卷包含哪些大题、按什么顺序排的、插图占位用了几处、哪些地方因为图片重叠或缺失做了去重和补齐。这段说明必须写在代码块外面，不要写进代码里，也不用教我怎么运行脚本，我会自动执行。
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
        docx = .idle

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

        // 规则固定打头，后面依次是试卷的每一页。顺序保持稳定便于排查日志，
        // 真正的页序由 AI 按卷面结构判断（提示词里已经说清楚）。
        var uploads = [FilePayload(url: ruleURL, name: "试卷识别规则.md", mime: "text/markdown")]
        uploads += paperFiles.map { FilePayload(url: $0, name: $0.lastPathComponent, mime: mimeFor($0)) }
        // 不同目录下的同名文件（比如两张都叫「IMG_0001.jpg」）在附件条里分不清，
        // 而且 checkNames 是按子串匹配的，重名会互相顶掉 —— 重名时补个序号。
        uploads = dedupeNames(uploads)

        // 提示词里的名字用**去重之后**的，跟附件条上显示的一致。第一个固定是规则。
        let paperNames = uploads.dropFirst().map { $0.name }
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
            detail: "一共 \(uploads.count) 个文件：规则 1 个、试卷 \(paperFiles.count) 个",
            fraction: 0.55, running: true)

        // 4. 等附件条渲染出来。
        // 等待时间按体积给：整份试卷几十张照片能到上百 MB，固定 25 秒根本不够。
        let waitSeconds = min(300, max(25, 20 + Double(totalBytes) / 1_000_000 * 3.0))
        var missing = try waitFor(expected(uploads), timeout: waitSeconds)
        log(missing.isEmpty
            ? "\(uploads.count) 个附件已就位（\(Int(totalBytes / 1024)) KB）"
            : "还没出现：\(missing.joined(separator: "、"))")

        // 4.1 .md 被拒收就改 .txt 重试，并同步替换提示词里的文件名
        if missing.contains("试卷识别规则.md") {
            log("DeepSeek 不收 .md，改用 .txt 重试")
            say("正在换一种格式重传规则文件…", fraction: 0.6, running: true)
            uploads[0].name = "试卷识别规则.txt"
            uploads[0].mime = "text/plain"
            prompt = prompt.replacingOccurrences(
                of: "《试卷识别规则.md》", with: "《试卷识别规则.txt》")

            let retry: [[String: Any]] = [
                ["idx": 0, "name": uploads[0].name, "type": uploads[0].mime]
            ]
            _ = try self.js(Scripts.commitFiles(defsJSON: jsonString(retry)))
            let still = try waitFor([(name: uploads[0].name, isImage: false)], timeout: 20)
            if !still.isEmpty {
                throw BridgeError.failed("规则文件传不上去，DeepSeek 可能既不收 .md 也不收 .txt")
            }
            missing.removeAll { $0 == "试卷识别规则.md" }
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
        var endMarkRounds = 0
        var lastChangeAt = Date()

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

            if textLen != lastTextLen || codeLen != lastCodeLen {
                lastChangeAt = Date()
                // 总上限就是 10 分钟：增长只影响“正在输出”的判断，不再延长总时间。
            }

            // 结束标记随时判定：即使 generating 还报 true（停止按钮残留 / 纯图标没认出来），
            // 只要标记连续两轮都在，就说明代码本身写完了，不用等到“没在生成”才认。
            // 下面的旧结束标记分支已删掉，避免一轮里重复计数、两轮变一轮。
            if hasEndMark {
                endMarkRounds += 1
                if endMarkRounds >= 2 {
                    log("看到结束标记 # ===EXAM-END===，判定写完")
                    say("脚本写完了", detail: "正在把它取回来…", running: true)
                    return try grabScript()
                }
            } else {
                endMarkRounds = 0
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
                    // DeepSeek 点完「继续」要先「想」一会儿才开始吐字，实测远超 3 秒。
                    // 等太短会把有效点击误判成无效，两次就直接抛错了。
                    var grew = false
                    for attempt in 0..<6 {
                        Thread.sleep(forTimeInterval: 2.0)
                        if let now = try? self.textLength(), now > before {
                            grew = true
                            log("继续生效（约 \(2 * (attempt + 1)) 秒后开始出字，涨了 \(now - before) 字）")
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
                        clicksIneffective += 1
                        log("点了 12 秒仍无新内容（无效 \(clicksIneffective)/2）")
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
    private func clickContinueButton() throws -> String {
        let raw = try self.js(Scripts.locateContinue)

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

    /// 把页面上的代码块取回来，挑出最像「生成试卷」的那段
    func grabScript() throws -> String? {
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
