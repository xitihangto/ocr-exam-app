import AppKit
import Foundation
import WebKit

/// 自检：base64 分片灌数据的真实耗时（`--feedperftest`）。
///
/// 用户 2026-10-29 反馈「上传极慢」，但一直没人量过到底多慢。
/// 这里把「Swift 编码 → 切片 → 逐片 evaluateJavaScript → JS 侧 atob 拼 File」
/// 四段分开计时，顺便对比 96000 和 524288 两种片大小。
///
/// 不需要网络：页面用 loadHTMLString 造一个空壳。
enum FeedPerfTest {

    static func run() {
        _ = NSApplication.shared

        let count = 12
        let bytesEach = 2 * 1024 * 1024
        print("样本   = \(count) 个文件 × \(bytesEach / 1024 / 1024)MB")

        let browser = BrowserController()
        browser.webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while !browser.isPageLoaded && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard browser.isPageLoaded else {
            print("❌ 空页面没加载出来")
            return
        }

        // 造数据（随机字节，避免被压缩之类的东西影响）
        var blobs: [Data] = []
        for _ in 0..<count {
            var data = Data(count: bytesEach)
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { arc4random_buf(base, bytesEach) }
            }
            blobs.append(data)
        }

        // ① Swift 侧 base64
        var t0 = Date()
        let encoded = blobs.map { $0.base64EncodedString() }
        let encodeSec = Date().timeIntervalSince(t0)
        let totalChars = encoded.reduce(0) { $0 + $1.count }
        print(String(format: "base64 = %.3f 秒（%d 字符）", encodeSec, totalChars))

        for step in [96000, 524288] {
            _ = js(browser.webView, "window.__wbF={}; 'OK'")
            var chunks = 0
            t0 = Date()
            for (index, b64) in encoded.enumerated() {
                var cursor = b64.startIndex
                while cursor < b64.endIndex {
                    let end = b64.index(cursor, offsetBy: step, limitedBy: b64.endIndex) ?? b64.endIndex
                    let chunk = String(b64[cursor..<end])
                    _ = js(browser.webView, Scripts.appendChunk(index: index, chunk: chunk))
                    cursor = end
                    chunks += 1
                }
            }
            let feedSec = Date().timeIntervalSince(t0)
            print(String(format: "分片 %6d → %4d 片，注入耗时 %.3f 秒（每片 %.2f ms）",
                         step, chunks, feedSec, feedSec / Double(chunks) * 1000))
        }

        // ③ JS 侧 atob + 拼 File 的耗时（只测一个文件，乘以 12 就是总量级）
        let defs = encoded.enumerated().map { i, _ in
            "{\"idx\":\(i),\"name\":\"f\(i).jpg\",\"type\":\"image/jpeg\"}"
        }.joined(separator: ",")
        t0 = Date()
        let result = js(browser.webView, Scripts.commitFiles(defsJSON: "[\(defs)]"))
        let commitSec = Date().timeIntervalSince(t0)
        print(String(format: "commit = %.3f 秒  %@", commitSec, result))

        // ④ 合成一次，看看总计
        print(String(format: "合计   ≈ %.3f 秒（编码 + 注入 96K + 组装）",
                     encodeSec + commitSec))
    }

    // MARK: - 工具

    private static func js(_ webView: WKWebView, _ code: String) -> String {
        var out = ""
        var done = false
        webView.evaluateJavaScript(code) { result, _ in
            if let text = result as? String {
                out = text
            } else if let number = result as? NSNumber {
                out = number.stringValue
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        return out
    }
}
