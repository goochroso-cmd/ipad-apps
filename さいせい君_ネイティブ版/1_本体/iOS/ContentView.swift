//
//  ContentView.swift
//  iさいせい君  v.in05「曲の引っ越し」
//
//  v.in04 までの中身は 2_過去版/v.in04_息継ぎ消し/ に退避した。
//  画面（Web版 v32）は 1 文字も触っていない。
//
//  ★ この版だけの「検査帯」を下に足している
//    引っ越しの状況と、Swift で1曲だけ鳴らす試聴ボタンを置いてある。
//    ★これは検査用。v.in06 で音の本線が Swift に移ったら丸ごと消す。★
//    「▼閉じる」を押せば畳めるので、画面をいつもの大きさで確かめることもできる。
//
//  ★★ 計器についての戒め（v.in04 の失敗・9.9章）
//    帯に出しているのは【ファイルの大きさ】と【経過した秒数】だけ。
//    どちらもファイルと時計が答えを持っている。機械が測ってよいもの。
//    ★音が効いたかどうかは、機械にいっさい判定させない。親分の耳が答え。★
//

import SwiftUI
import UIKit

struct ContentView: View {

    /// 画面に必ず出す版数（決定と教訓 第6章のルール）
    private let version = "v.in05 曲の引っ越し"

    @StateObject private var state = WebScreenState()
    @StateObject private var vault = SongVault.shared
    @State private var showPanel = true

    var body: some View {
        VStack(spacing: 0) {

            ZStack(alignment: .topTrailing) {
                Color.black
                WebScreen(fileName: "saisei_v32", state: state)

                if let err = state.patchError {
                    Text("★パッチ未適用: \(err)")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.78, green: 0.12, blue: 0.20))
                        .cornerRadius(6)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }

            panel
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .horizontal)
        .onAppear { keepScreenOn() }
    }

    // MARK: - 検査帯（この版かぎり）

    private var panel: some View {
        VStack(spacing: 0) {

            Divider().background(Color(white: 0.35))

            HStack(spacing: 14) {

                Text(version)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Color(red: 1.0, green: 0.84, blue: 0.04))
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vault.statusLine)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !vault.detailLine.isEmpty {
                        Text(vault.detailLine)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(white: 0.72))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(showPanel ? "▼ 閉じる" : "▲ 検査帯") {
                    showPanel.toggle()
                }
                .font(.system(size: 19, weight: .heavy))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.22))
                .cornerRadius(8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if showPanel {
                buttons
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .background(Color(white: 0.08))
    }

    private var buttons: some View {
        HStack(spacing: 12) {

            if vault.songs.isEmpty {
                Text("試聴できる曲はまだありません。曲を1つ登録すると、ここに出ます。")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Color(white: 0.75))
                Spacer()

            } else {

                bigButton(vault.playing ? "■ 止める" : "▶ Swiftで鳴らす",
                          color: vault.playing
                              ? Color(red: 0.72, green: 0.16, blue: 0.16)
                              : Color(red: 0.10, green: 0.52, blue: 0.34)) {
                    if vault.playing { vault.testStop() } else { vault.testPlay() }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(vault.pickedName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(vault.pick + 1) / \(vault.songs.count) 曲目")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(white: 0.6))
                }
                .frame(maxWidth: 220, alignment: .leading)

                bigButton("次の曲", color: Color(white: 0.26)) { vault.nextSong() }

                Spacer(minLength: 6)

                // ★ ここが v.in05 の本命。★効いたかどうかは耳で判断すること★
                Text("音量\n★耳で")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.04))
                    .multilineTextAlignment(.trailing)

                volButton("小", 0.15)
                volButton("中", 0.5)
                volButton("大", 1.0)
            }
        }
        .frame(height: 58)
    }

    private func bigButton(_ title: String, color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .frame(height: 54)
                .background(color)
                .cornerRadius(10)
        }
    }

    private func volButton(_ title: String, _ v: Float) -> some View {
        let on = abs(vault.testVolume - v) < 0.01
        return Button(action: { vault.setTestVolume(v) }) {
            Text(title)
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(on ? .black : .white)
                .frame(width: 66, height: 54)
                .background(on ? Color(red: 1.0, green: 0.84, blue: 0.04) : Color(white: 0.26))
                .cornerRadius(10)
        }
    }

    private func keepScreenOn() {
        // 本番中に画面が勝手に暗くなる／ロックするのを止める（合格表 5-5）
        UIApplication.shared.isIdleTimerDisabled = true
    }
}
