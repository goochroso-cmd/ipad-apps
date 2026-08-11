//
//  WebScreen.swift
//  iさいせい君  v.in05「曲の引っ越し」
//
//  ★ 何をしているか（1行で）
//    5ヶ月かけて作った Web版の画面を、そのままアプリの中で開いている。
//    HTML には 1 文字も触らず、外からパッチを流し込んで中身だけ入れ替える。
//
//  ★ 流し込んでいるパッチ（順番に意味がある）
//    1. no_webaudio_patch.js … v.in04。Web Audio 経路を切る＝息継ぎが消える
//    2. export_to_swift.js   … v.in05。曲を Swift 側へ引っ越しさせる
//
//  ★ v.in04 までに実機が出した答え（2026-08-11 親分）
//      画面の速さ            ○（設定の開閉だけ少し遅いが許容範囲）
//      保存（設定・曲7曲）   ○ file:// でも生きていた
//      息継ぎ                ○ 消えた（Web Audio を切ったため）
//      音量・フェード        × 死んだ（<audio>.volume は iOS で音に反映されない）
//
//    → WebKit の中に居る限りこの二択からは逃げられないことが確定した。
//      残された道は AVAudioPlayer だけ。その第一歩がこの v.in05。
//
//  ★ v.in05 では音の本線を触っていない。
//    触ったら「引っ越しが遅いのか、差し替えが悪いのか」が切り分けられなくなる。
//    音の差し替えは v.in06。
//

import SwiftUI
import WebKit

// 画面（SwiftUI 側）へ結果を伝えるための小さな箱
final class WebScreenState: ObservableObject {
    /// パッチそのものが読み込めなかったときの説明（正常なら nil）
    @Published var patchError: String? = nil
}

struct WebScreen: UIViewRepresentable {

    /// Resources に入れた HTML のファイル名（拡張子なし）
    let fileName: String

    @ObservedObject var state: WebScreenState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    // MARK: - JS からの連絡を受け取る係

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let state: WebScreenState
        weak var web: WKWebView?

        init(state: WebScreenState) { self.state = state }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let type = dict["t"] as? String else { return }

            // ★ JS が「Swift 側に今なにが有る？」と聞いてきた。
            //   同じ曲を毎回 140MB 流し直さないための問い合わせ。
            if type == "vaultAsk" {
                let json = SongVault.shared.inventoryJSON()
                let escaped = json
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                web?.evaluateJavaScript("window.__saiseiVault.onList('\(escaped)')",
                                        completionHandler: nil)
                return
            }

            // それ以外の vault... は全部、受け皿へそのまま渡す
            if type.hasPrefix("vault") {
                SongVault.shared.receive(dict)
            }
        }
    }

    // MARK: - パッチの読み込み

    /// Resources の .js を読んで、HTML の直後に流し込む形にする
    private func userScript(_ name: String) -> WKUserScript? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            // 黙って失敗させない。画面に出す（決定と教訓 第2章の教え）
            DispatchQueue.main.async {
                let old = state.patchError.map { $0 + " / " } ?? ""
                state.patchError = old + "\(name).js が見つかりません"
            }
            return nil
        }
        return WKUserScript(source: js,
                            injectionTime: .atDocumentEnd,   // HTML の中の script が走り終わった後
                            forMainFrameOnly: true)
    }

    // MARK: - 画面を作る

    func makeUIView(context: Context) -> WKWebView {

        let cfg = WKWebViewConfiguration()
        // 音を画面いっぱいに乗っ取らせない（勝手に全画面プレイヤーにしない）
        cfg.allowsInlineMediaPlayback = true
        // 「人が触るまで鳴らさない」という縛りを外す
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // 登録した曲を残すための保存領域（v.in03 の実機で、これが生きていることを確認済み）
        cfg.websiteDataStore = .default()

        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "saisei")     // JS → Swift の窓口
        if let s = userScript("no_webaudio_patch") { ucc.addUserScript(s) }
        if let s = userScript("export_to_swift")   { ucc.addUserScript(s) }
        cfg.userContentController = ucc

        let web = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.web = web      // Swift → JS の呼び返しに使う

        // 本番は暗がり。白い地が一瞬でも出ないように
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black

        // ★ 演奏中の誤操作を防ぐ
        web.scrollView.bounces = false                        // 画面がびよんと動かない
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false       // 端をなぞって「戻る」が出ない

        if let url = Bundle.main.url(forResource: fileName, withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // 黙って真っ暗にしない。何が起きたか画面に出す（決定と教訓 第2章の教え）
            web.loadHTMLString("""
                <body style="background:#000;color:#ffd60a;font-size:34px;
                             font-family:-apple-system;padding:40px;line-height:1.6">
                  <b>HTMLが見つかりません</b><br>
                  さがした名前: \(fileName).html<br><br>
                  1_本体/iOS/Resources/ に入っているか確認してください。
                </body>
                """, baseURL: nil)
        }

        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 画面から指示することは今は無い
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "saisei")
    }
}
