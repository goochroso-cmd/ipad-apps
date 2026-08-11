//
//  SaiseiApp.swift
//  iさいせい君（さいせい君 ネイティブ版）
//
//  ★ このファイルは v.in01 から一度も変わっていない。
//    やっているのは「消音スイッチが入っていても鳴る」設定だけ。
//    本番の道具なので、ここは絶対に外さない。
//

import SwiftUI
import AVFoundation

@main
struct SaiseiApp: App {

    init() {
        // ─────────────────────────────────────────────
        // 音を出す準備。
        // .playback にすると「マナースイッチ（消音）が入っていても鳴る」。
        // 本番の道具なので、ここは絶対に外せない。
        // ─────────────────────────────────────────────
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
