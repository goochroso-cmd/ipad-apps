//
//  PadBank.swift
//  9個の AVAudioPlayer を持っておく箱。
//
//  ★ ここが Web版とのいちばん大きな違い。
//    Web（iOS Safari）は「人が画面を触った、その瞬間」にしか読み込みを始められなかった。
//    ネイティブは prepareToPlay() で【アプリ起動時に、裏で先に全部用意しておける】。
//    だから「準備中…」が要らない。
//

import Foundation
import AVFoundation
import Combine

final class PadBank: NSObject, ObservableObject, AVAudioPlayerDelegate {

    struct Pad: Identifiable {
        let id: Int          // 1〜9
        let label: String    // ボタンに出す文字
        let file: String     // 音のファイル名（拡張子なし）
    }

    /// 3×3 の並び。今は動作確認用の音階が入っているだけ。
    let pads: [Pad] = [
        Pad(id: 1, label: "ド",   file: "tone_1_do"),
        Pad(id: 2, label: "レ",   file: "tone_2_re"),
        Pad(id: 3, label: "ミ",   file: "tone_3_mi"),
        Pad(id: 4, label: "ファ", file: "tone_4_fa"),
        Pad(id: 5, label: "ソ",   file: "tone_5_so"),
        Pad(id: 6, label: "ラ",   file: "tone_6_la"),
        Pad(id: 7, label: "シ",   file: "tone_7_si"),
        Pad(id: 8, label: "ド↑", file: "tone_8_do_hi"),
        Pad(id: 9, label: "レ↑", file: "tone_9_re_hi")
    ]

    /// いま鳴っているパッドの番号
    @Published private(set) var playing: Set<Int> = []
    /// 起動時の準備結果。失敗したら画面に出す（黙って失敗させない）
    @Published private(set) var loadError: String? = nil

    // ─────────────────────────────────────────────
    // ★ v1.1 「ブツ」対策（2026-08-11 実機で親分が発見）
    //
    //   音の波は、なめらかな坂。stop() はその途中でハサミを入れる。
    //   波が高い位置にいるときに切ると、そこから一気にゼロへ落ちる。
    //   この「垂直な段差」がスピーカーに衝撃として伝わる ＝「ブツ」。
    //
    //   だから止める直前に、ごく短い坂を作ってから切る。
    //   40ミリ秒。まばたきの10分の1。人には「すぐ止まった」としか聞こえない。
    //
    //   ★ あとで作る「曲ごとのフェードアウト設定」（合格表 4-2）とは別物。
    //     あちらは演出。こちらは雑音取り。混ぜないこと。
    // ─────────────────────────────────────────────
    private let clickGuard: TimeInterval = 0.04

    private var players: [Int: AVAudioPlayer] = [:]
    private var owner: [ObjectIdentifier: Int] = [:]   // player → パッド番号

    /// 坂を下っている最中のパッド（まだ isPlaying は true のまま）
    private var fading: Set<Int> = []
    /// 停止予約の通し番号。坂の途中でもう一度押されたら、古い予約を無効にする
    private var stopGen: [Int: Int] = [:]

    override init() {
        super.init()

        var missing: [String] = []

        for pad in pads {
            guard let url = Bundle.main.url(forResource: pad.file, withExtension: "wav") else {
                missing.append(pad.file)
                continue
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.volume = 1.0
                // ★ 裏で先に用意しておく。Web版ではこれができなかった
                p.prepareToPlay()
                players[pad.id] = p
                owner[ObjectIdentifier(p)] = pad.id
            } catch {
                missing.append("\(pad.file)（\(error.localizedDescription)）")
            }
        }

        if !missing.isEmpty {
            loadError = "用意できなかった音: " + missing.joined(separator: " / ")
        }
    }

    /// パッドを押したとき。鳴っていなければ鳴らす、鳴っていれば止める。
    func tap(_ id: Int) {
        guard let p = players[id] else { return }

        if p.isPlaying && !fading.contains(id) {
            stopSmooth(id)
        } else {
            start(id)
        }
    }

    /// 全部止める（パニックボタン）。★ここも同じ坂を通す（v1.1）
    func stopAll() {
        for pad in pads where players[pad.id]?.isPlaying == true {
            stopSmooth(pad.id)
        }
        playing.removeAll()
    }

    // MARK: - 中身

    private func start(_ id: Int) {
        guard let p = players[id] else { return }

        // 坂の途中だったら、その停止予約を捨てる（押し直しを優先する）
        stopGen[id, default: 0] += 1
        fading.remove(id)

        // 坂の途中は音量がほぼゼロなので、ここで切っても「ブツ」は出ない
        p.stop()
        p.volume = 1.0
        // ★ 頭出し。ネイティブなら currentTime で正確に戻せる（Web版の息継ぎ対策）
        // ★ 既に0なら書かない（決定と教訓：iPadのシークは重い）
        if p.currentTime != 0 { p.currentTime = 0 }
        p.play()
        playing.insert(id)
    }

    /// 40ミリ秒だけ坂を下ってから止める。「ブツ」が出ない止め方。
    private func stopSmooth(_ id: Int) {
        guard let p = players[id] else { return }

        stopGen[id, default: 0] += 1
        let gen = stopGen[id]!
        fading.insert(id)

        p.setVolume(0, fadeDuration: clickGuard)

        // 見た目（緑の消灯）は待たせない。押した手応えを先に返す
        playing.remove(id)

        DispatchQueue.main.asyncAfter(deadline: .now() + clickGuard) { [weak self] in
            guard let self = self else { return }
            // 坂の途中で押し直されていたら、この予約は無効
            guard self.stopGen[id] == gen else { return }
            p.stop()
            self.rewind(p)
            self.fading.remove(id)
        }
    }

    private func rewind(_ p: AVAudioPlayer) {
        p.currentTime = 0
        p.volume = 1.0          // ★ 坂で下げた音量を必ず戻す（v1.1）
        p.prepareToPlay()
    }

    // 曲が終わりまで鳴りきったとき（自然に終わるので「ブツ」は出ない）
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let id = owner[ObjectIdentifier(player)] else { return }
        rewind(player)
        DispatchQueue.main.async { [weak self] in
            self?.fading.remove(id)
            self?.playing.remove(id)
        }
    }
}
