//
//  SongVault.swift
//  iさいせい君  v.in05「曲の引っ越し」
//
//  ★ このファイルがやること（1行で）
//    ブラウザの倉庫から送られてきた曲を、アプリの Documents フォルダへ書き出す。
//    そして「その曲を AVAudioPlayer が本当に鳴らせるか」を、親分の耳で確かめる
//    ための試聴ボタンを1つだけ持っている。
//
//  ★ なぜこの版を作ったか
//    紙（10章）には「窓口13個を Swift へ差し替える」と書いてある。
//    しかしコードを開いたら、その前に壁が1つあった。
//    ── Swift は IndexedDB の扉を開けられない。
//    曲を引っ越しさせないと、AVAudioPlayer は鳴らす物を1つも持っていない。
//
//    そして「Air 2（2014年・メモリ2GB）で 140MB の引っ越しが何秒かかるか」は
//    机の上では分からない。ここが遅すぎたら設計を変える必要がある。
//    だから引っ越しだけを先に作って、実機で測る。
//
//  ★ 計器についての戒め（v.in04 の失敗・0_仕様 と はじめに読む 9.9章）
//    「音が効いているか」を機械に判定させてはいけない。音は耳でしか分からない。
//    このファイルが画面に出すのは【ファイルの大きさ】と【経過した秒数】だけ。
//    どちらもファイルと時計が答えを持っていて、機械が測ってよいもの。
//    ★音そのものの合否は、親分が試聴ボタンを押して耳で決める。★
//

import Foundation
import AVFoundation
import Combine

/// 引っ越してきた曲1つぶんの覚え書き
struct SongMeta: Codable {
    var name: String
    var mime: String
    var bytes: Int
    var file: String
}

final class SongVault: NSObject, ObservableObject, AVAudioPlayerDelegate {

    static let shared = SongVault()

    // MARK: - 画面に出すもの（すべて「ファイル」か「時計」が答えを持っている値）

    /// 大きい一行（引っ越しの状況）
    @Published var statusLine: String = "曲の引っ越し: 起動を待っています"
    /// 小さい一行（内訳・経過時間）
    @Published var detailLine: String = ""
    /// 引っ越し済みの曲（試聴ボタンで選べるもの）
    @Published var songs: [(index: Int, name: String, bytes: Int)] = []
    /// いま試聴している曲の位置（songs の何番目か）
    @Published var pick: Int = 0
    /// 試聴中か
    @Published var playing: Bool = false
    /// 試聴の音量（0.0〜1.0）★この数字ではなく、耳で判断すること
    @Published var testVolume: Float = 1.0

    // MARK: - しまい場所

    private let dir: URL
    private var meta: [String: SongMeta] = [:]

    // MARK: - 受け取り中の1曲

    private var writer: FileHandle?
    private var curIndex: Int = -1
    private var curURL: URL?
    private var curExpected: Int = 0
    private var curGot: Int = 0
    private var curName: String = ""
    private var curMime: String = ""
    private var nextSeq: Int = 0

    // MARK: - 全体の進み具合

    private var planSend: Int = 0
    private var planSkip: Int = 0
    private var doneCount: Int = 0
    private var totalBytes: Int = 0

    // MARK: - 試聴

    private var player: AVAudioPlayer?

    // MARK: - 立ち上がり

    private override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("pads", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadMeta()
        refreshSongs()
    }

    // MARK: - 覚え書きの読み書き

    private var metaURL: URL { dir.appendingPathComponent("meta.json") }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let m = try? JSONDecoder().decode([String: SongMeta].self, from: data) else { return }
        meta = m
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    /// 覚え書きと実物を突き合わせて、ちゃんと有るものだけを一覧に載せる。
    /// （引っ越しの途中でアプリが落ちた場合、書きかけのファイルが残るため）
    private func refreshSongs() {
        var list: [(index: Int, name: String, bytes: Int)] = []
        var fixed: [String: SongMeta] = [:]

        for (key, m) in meta {
            let url = dir.appendingPathComponent(m.file)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int
            if let s = size, s == m.bytes, let idx = Int(key) {
                fixed[key] = m
                list.append((index: idx, name: m.name, bytes: m.bytes))
            } else {
                try? FileManager.default.removeItem(at: url)   // 書きかけは捨てる
            }
        }

        meta = fixed
        list.sort { $0.index < $1.index }
        songs = list
        if pick >= list.count { pick = 0 }
    }

    /// JS へ返す在庫表 { "7": 15234567, ... }
    func inventoryJSON() -> String {
        refreshSongs()
        var d: [String: Int] = [:]
        for s in songs { d[String(s.index)] = s.bytes }
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - JS から届く連絡をさばく

    func receive(_ dict: [String: Any]) {
        guard let t = dict["t"] as? String else { return }

        switch t {

        case "vaultPlan":
            planSend = dict["send"] as? Int ?? 0
            planSkip = dict["skip"] as? Int ?? 0
            doneCount = 0
            totalBytes = 0
            if planSend == 0 {
                statusLine = planSkip > 0
                    ? "曲の引っ越し: 済み（\(planSkip)曲はもうアプリの中にあります）"
                    : "曲の引っ越し: 運ぶ曲がありません（まだ1曲も登録されていません）"
                detailLine = ""
            } else {
                statusLine = "曲の引っ越し: これから \(planSend)曲 を運びます"
                detailLine = planSkip > 0 ? "\(planSkip)曲 はもう有るので飛ばします" : ""
            }

        case "vaultBegin":
            beginOne(dict)

        case "vaultChunk":
            takeChunk(dict)

        case "vaultEnd":
            endOne()

        case "vaultFail":
            abortOne(reason: dict["msg"] as? String ?? "原因不明")

        case "vaultAllDone":
            let ms = dict["ms"] as? Int ?? 0
            finishAll(ms: ms)

        case "vaultNone":
            statusLine = "曲の引っ越し: 始められませんでした"
            detailLine = dict["why"] as? String ?? ""

        default:
            break
        }
    }

    // MARK: - 1曲ぶんの受け取り

    private func beginOne(_ dict: [String: Any]) {
        closeHandle()

        curIndex = dict["i"] as? Int ?? -1
        curExpected = dict["size"] as? Int ?? 0
        curName = dict["name"] as? String ?? "名前なし"
        curMime = dict["mime"] as? String ?? "audio/mpeg"
        curGot = 0
        nextSeq = 0

        let fileName = String(format: "pad_%03d.%@", curIndex, Self.ext(for: curMime))
        let url = dir.appendingPathComponent(fileName)
        curURL = url

        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        writer = try? FileHandle(forWritingTo: url)

        statusLine = "曲の引っ越し: \(doneCount + 1)曲目「\(curName)」を運んでいます"
        detailLine = "0 / \(Self.mb(curExpected))"
    }

    private func takeChunk(_ dict: [String: Any]) {
        guard let h = writer,
              (dict["i"] as? Int) == curIndex,
              let b64 = dict["b64"] as? String else { return }

        // 順番の確認。postMessage は順番どおりに届く決まりだが、
        // 崩れていたら黙って壊れたファイルを作らずに、その場で止める。
        let seq = dict["seq"] as? Int ?? nextSeq
        if seq != nextSeq {
            abortOne(reason: "細切れの順番が狂いました（\(nextSeq) を待っていたのに \(seq) が来た）")
            return
        }
        nextSeq += 1

        guard let data = Data(base64Encoded: b64) else {
            abortOne(reason: "細切れの中身を戻せませんでした")
            return
        }

        do { try h.write(contentsOf: data) }
        catch { abortOne(reason: "書き込みに失敗しました: \(error.localizedDescription)"); return }

        curGot += data.count
        detailLine = "\(Self.mb(curGot)) / \(Self.mb(curExpected))"
    }

    private func endOne() {
        closeHandle()
        guard curIndex >= 0, let url = curURL else { return }

        if curGot != curExpected {
            abortOne(reason: "大きさが合いません（\(curGot) / \(curExpected)）")
            return
        }

        meta[String(curIndex)] = SongMeta(name: curName, mime: curMime,
                                          bytes: curGot, file: url.lastPathComponent)
        saveMeta()
        refreshSongs()

        doneCount += 1
        totalBytes += curGot
        curIndex = -1
        curURL = nil
    }

    private func abortOne(reason: String) {
        closeHandle()
        if let url = curURL { try? FileManager.default.removeItem(at: url) }
        statusLine = "★曲の引っ越しで止まりました"
        detailLine = reason
        curIndex = -1
        curURL = nil
    }

    private func finishAll(ms: Int) {
        closeHandle()
        refreshSongs()

        let sec = Double(ms) / 1000.0
        if doneCount == 0 && planSend == 0 {
            // vaultPlan で出した文言のままでよい
            return
        }
        statusLine = "曲の引っ越し: \(doneCount)曲 完了（アプリの中に \(songs.count)曲）"
        detailLine = String(format: "%@ を %.1f秒で運びました", Self.mb(totalBytes), sec)
    }

    private func closeHandle() {
        try? writer?.close()
        writer = nil
    }

    // MARK: - 試聴（★ここが v.in05 の本命。親分の耳が答えを出す）

    /// いま選んでいる曲を、Swift（AVAudioPlayer）で鳴らす。
    /// 画面の HTML はいっさい通らない。音の出口は完全に Swift 側。
    func testPlay() {
        guard !songs.isEmpty else {
            statusLine = "試聴できる曲がありません"
            return
        }
        let s = songs[min(pick, songs.count - 1)]
        guard let m = meta[String(s.index)] else { return }
        let url = dir.appendingPathComponent(m.file)

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.volume = testVolume
            p.prepareToPlay()
            p.play()
            player = p
            playing = true
        } catch {
            statusLine = "★Swift で鳴らせませんでした"
            detailLine = "\(m.name): \(error.localizedDescription)"
            playing = false
        }
    }

    func testStop() {
        player?.stop()
        player = nil
        playing = false
    }

    /// 鳴っている最中に音量を変える。★効いたかどうかは耳で確かめること
    func setTestVolume(_ v: Float) {
        testVolume = v
        player?.volume = v
    }

    func nextSong() {
        guard !songs.isEmpty else { return }
        pick = (pick + 1) % songs.count
        if playing { testStop(); testPlay() }
    }

    var pickedName: String {
        guard !songs.isEmpty else { return "曲なし" }
        return songs[min(pick, songs.count - 1)].name
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = false
    }

    // MARK: - 小道具

    private static func ext(for mime: String) -> String {
        let m = mime.lowercased()
        if m.contains("mpeg") || m.contains("mp3") { return "mp3" }
        if m.contains("wav")  { return "wav" }
        if m.contains("aiff") { return "aif" }
        if m.contains("mp4") || m.contains("m4a") || m.contains("aac") { return "m4a" }
        if m.contains("flac") { return "flac" }
        if m.contains("ogg")  { return "ogg" }   // iOS では鳴らないが、捨てずに置く
        return "bin"
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1024.0 / 1024.0)
    }
}
