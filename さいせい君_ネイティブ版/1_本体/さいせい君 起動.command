#!/bin/bash
# ============================================================
#  さいせい君 起動.command  (v1.0)
#  さいせい君ネイティブ版を iPad Air 2 に入れて起動する
#
#  使い方: iPad を USB で挿して、このファイルをダブルクリック
#
#  中身は opendisplay/00_ツールとメモ/サブディスプレイ起動.command の
#  実績のある作りを流用している（親分が7月に完成させたもの）。
#  違うのは「2/6 プロジェクトを組み立てる」が増えたことだけ。
# ============================================================

# このファイルが置いてあるフォルダ（移動しても自分で見つける）
HERE="$(cd "$(dirname "$0")" && pwd)"

# Homebrew のコマンドが見えるようにしておく（ダブルクリック起動の保険）
for P in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$P:"*) ;; *) [ -d "$P" ] && PATH="$P:$PATH" ;; esac
done
export PATH

SRC="$HERE"
PROJ="$SRC/Saisei.xcodeproj"
SCHEME="Saisei"
BUNDLE="com.goochroso.saiseikun"
BUILDDIR="$SRC/.build"
STAMP="$HOME/.saiseikun_last_install"
LOG="$HERE/ビルド_ログ.txt"
INSTLOG="$HERE/インストール_ログ.txt"

AUTO_CLOSE_TERMINAL=0   # 最初のうちは画面を残す（結果をチャットに貼れるように）

B=$(printf '\033[1m'); R=$(printf '\033[0m')
GREEN=$(printf '\033[1;32m'); RED=$(printf '\033[1;31m'); YEL=$(printf '\033[1;33m')
LINE="============================================================"

title() { echo ""; echo "${B}${LINE}${R}"; echo "${B}  $1${R}"; echo "${B}${LINE}${R}"; echo ""; }
step()  { echo ""; echo "${B}【$1】${R} $2"; echo ""; }
ok()    { echo "  ${GREEN}OK  $1${R}"; }
ng()    { echo "  ${RED}NG  $1${R}"; }
warn()  { echo "  ${YEL}--  $1${R}"; }
info()  { echo "      $1"; }
pause_enter() { echo ""; read -r -p "  準備ができたら Enter キーを押してください... " _; echo ""; }

finish_ok() {
  echo ""; echo "${B}${LINE}${R}"; echo "$1"; echo "${B}${LINE}${R}"; echo ""
  read -r -p "  Enter キーでこのウィンドウを閉じます... " _
  exit 0
}

finish_ng() {
  echo ""; echo "${B}${LINE}${R}"; echo "$1"; echo "${B}${LINE}${R}"; echo ""
  info "この画面は閉じません。${B}上の内容をそのままチャットに貼ってください。${R}"
  echo ""
  read -r -p "  Enter キーでこのウィンドウを閉じます... " _
  exit "${2:-1}"
}

clear
title "さいせい君 起動ツール  v1.0（土台）"
echo "  9個のボタンを押すと音が出る、それだけを確かめる版です。"
echo "  曲の登録・設定・ページ切替は、まだ入っていません。"
echo ""

# ---------- 1 / 6 環境チェック ----------
step "1 / 6" "環境をチェックしています"

if ! xcode-select -p >/dev/null 2>&1; then
  ng "Xcode のコマンドラインツールが見つかりません"
  finish_ng "  中断しました。" 1
fi
ok "Xcode を確認しました"

if ! command -v xcodegen >/dev/null 2>&1; then
  warn "xcodegen が入っていません"
  info "Xcode プロジェクトを組み立てる道具です。1〜2分で入ります。"
  echo ""
  if ! command -v brew >/dev/null 2>&1; then
    ng "Homebrew が見つかりません"
    info "探した場所: /opt/homebrew/bin, /usr/local/bin"
    finish_ng "  中断しました。" 1
  fi
  read -r -p "  今すぐ入れますか？ [Y/n]: " ANS
  case "$ANS" in
    n|N) finish_ng "  中断しました。xcodegen が無いと先に進めません。" 1 ;;
    *)   brew install xcodegen || finish_ng "  xcodegen の導入に失敗しました。" 1 ;;
  esac
fi
ok "xcodegen を確認しました（$(xcodegen --version 2>/dev/null | head -n1)）"

# ---------- 2 / 6 プロジェクトを組み立てる ----------
step "2 / 6" "Xcode プロジェクトを組み立てています"

cd "$SRC" || finish_ng "  フォルダに入れませんでした: $SRC" 1
if xcodegen generate --spec "$SRC/project.yml" --project "$SRC" 2>&1 | tail -n 10; then
  ok "組み立てました: Saisei.xcodeproj"
else
  ng "組み立てに失敗しました（project.yml の中身を確認してください）"
  finish_ng "  中断しました。" 1
fi

[ -d "$PROJ" ] || finish_ng "  プロジェクトができていません: $PROJ" 1

# ---------- 3 / 6 iPad の接続チェック ----------
step "3 / 6" "iPad の接続をチェックしています"

HEX40='[0-9a-fA-F]{40}'
HEX8_16='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}'
DEVNAME=""

find_ipad() {
  local line u=""
  line=$(xcodebuild -project "$PROJ" -scheme "$SCHEME" -showdestinations 2>/dev/null \
         | grep 'platform:iOS,' | grep -v -i 'simulator' | grep -v -i 'placeholder' | head -n 1)
  if [ -n "$line" ]; then
    u=$(echo "$line" | sed -E 's/.*id:([^,}]+).*/\1/' | tr -d ' ')
    DEVNAME=$(echo "$line" | sed -E 's/.*name:([^}]+)\}.*/\1/' | sed 's/[[:space:]]*$//')
    if [ -n "$u" ]; then echo "$u"; return; fi
  fi
  u=$(xcrun xctrace list devices 2>/dev/null | grep -Ei 'ipad' \
      | grep -Eo "$HEX40|$HEX8_16" | head -n 1)
  echo "$u"
}

UDID="$(find_ipad)"

if [ -z "$UDID" ]; then
  warn "Xcode から iPad が見えていません"
  echo ""
  echo "  ${B}確認してください${R}"
  info "1. iPad の画面のロックを解除する（これが一番よくある原因）"
  info "2. 「このコンピュータを信頼しますか？」→ ${B}信頼${R} をタップ"
  info "3. 出ない場合はケーブルを一度抜いて挿し直す"
  pause_enter
  UDID="$(find_ipad)"
fi

if [ -z "$UDID" ]; then
  ng "iPad が見つかりませんでした"
  finish_ng "  中断しました。" 1
fi
ok "iPad を検出しました"
[ -n "$DEVNAME" ] && info "名前: $DEVNAME"
info "識別番号: $UDID"

# ---------- 4 / 6 ビルド（7日の署名切れ対策） ----------
SKIP_BUILD=0
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null)
  NOW=$(date +%s)
  DAYS=$(( (NOW - LAST) / 86400 ))
  echo ""
  if [ "$DAYS" -lt 7 ]; then
    ok "前回のインストールから ${DAYS} 日。まだ有効期限内です（7日まで）"
    read -r -p "  ビルドを飛ばして、すぐ起動しますか？ [y/N]: " ANS
    case "$ANS" in y|Y) SKIP_BUILD=1 ;; esac
  else
    warn "前回のインストールから ${DAYS} 日。期限切れです。署名し直します"
  fi
fi

if [ "$SKIP_BUILD" = "1" ]; then
  step "4 / 6" "ビルドは省略します"
else
  step "4 / 6" "アプリをビルドして署名しています"
  info "初回は3〜5分かかります。コーヒーでもどうぞ。"
  echo ""
  if xcodebuild \
      -project "$PROJ" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination "id=$UDID" \
      -derivedDataPath "$BUILDDIR" \
      -allowProvisioningUpdates \
      build 2>&1 | tee "$LOG" | tail -n 25
  then
    ok "ビルド成功"
  else
    ng "ビルドに失敗しました"
    echo ""
    info "${B}よくある原因${R}"
    info "1. 無料 Apple ID の3アプリ枠が満杯"
    info "   → iPad から使っていないデベロッパAppを1つ消す"
    info "2. Apple ID の署名が切れている"
    info "   → Xcode ▸ メニュー「Xcode」▸「Settings…」▸「Accounts」タブ"
    info "全文のログ: $LOG"
    finish_ng "  中断しました。" 1
  fi
fi

# ---------- 5 / 6 インストール ----------
step "5 / 6" "iPad へインストールしています"

APP=""
if [ -d "$BUILDDIR/Build/Products/Debug-iphoneos" ]; then
  APP=$(find "$BUILDDIR/Build/Products/Debug-iphoneos" -maxdepth 1 -name "*.app" | head -n 1)
fi

INSTALLED=0
: > "$INSTLOG"

if [ "$SKIP_BUILD" = "1" ] && [ -z "$APP" ]; then
  ok "インストール済みのものを使います"
  info "iPad のホーム画面で「さいせい君」のアイコンをタップしてください。"
  INSTALLED=1
elif [ -z "$APP" ]; then
  ng "ビルドしたアプリが見つかりません: $BUILDDIR/Build/Products/Debug-iphoneos"
  finish_ng "  中断しました。" 1
else
  info "方法A（新しい方式）を試しています..."
  if xcrun devicectl device install app --device "$UDID" "$APP" >>"$INSTLOG" 2>&1; then
    ok "方法A で成功しました"
    xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >>"$INSTLOG" 2>&1
    INSTALLED=1
  else
    warn "方法A は使えませんでした（iPadOS 15 では想定内です）"
    info "方法B（古い機種向け）を試しています..."
    if command -v ios-deploy >/dev/null 2>&1; then
      ios-deploy --id "$UDID" --bundle "$APP" --no-wifi --justlaunch >>"$INSTLOG" 2>&1
      RC=$?
      # ★ ios-deploy は成功しても 0 以外を返すことがある。
      #   終了コードだけで判定すると、成功を失敗と誤読する（opendisplay v3.2 の教訓）
      if [ "$RC" = "0" ] || grep -q "Installed package" "$INSTLOG"; then
        ok "方法B で成功しました"
        [ "$RC" = "0" ] || info "（終了コードは $RC でしたが、インストールは完了しています）"
        INSTALLED=1
      else
        ng "方法B も失敗しました"
        echo ""
        info "${B}失敗した理由（最後の8行）${R}"
        tail -n 8 "$INSTLOG" | sed 's/^/      /'
        info "全文: $INSTLOG"
      fi
    else
      ng "ios-deploy が入っていません"
      info "opendisplay では 1.12.2 が使われています。入っているはずですが見つかりません。"
    fi
  fi
fi

if [ "$INSTALLED" != "1" ]; then
  echo ""
  info "${B}Xcode で手動インストールする場合${R}"
  info "1. Enter を押すと Xcode が開きます"
  info "2. 左上の表示を「${SCHEME} > iPad」にする"
  info "3. コマンド + R を押す"
  info "4. 「信頼されていないデベロッパ」と出たら iPad で"
  info "   設定 ▸ 一般 ▸ VPNとデバイス管理 ▸ 自分の名前 ▸ 信頼"
  pause_enter
  open "$PROJ"
  read -r -p "  iPad でアプリが起動したら Enter を押してください... " _
  INSTALLED=1
fi

date +%s > "$STAMP"

# ---------- 6 / 6 ここから親分の出番 ----------
step "6 / 6" "実機で確かめてください"

echo "  ${B}この版で確かめること（これだけ）${R}"
echo ""
info "1. iPad で「さいせい君」が起動する"
info "2. 9個のボタンが 3×3 に並んでいる。左上に ${B}v1.0 土台${R} と出ている"
info "3. ${B}どのボタンを押しても、すぐ音が出る${R}（ドレミ…の音が3秒）"
info "4. ${B}マナースイッチ（消音）が入っていても音が出る${R}"
info "5. 2つ以上のボタンを続けて押すと、${B}重なって鳴る${R}"
info "6. 鳴っているボタンは ${B}緑に光る${R}。もう一度押すと止まる"
info "7. 「ぜんぶ止める」で全部止まる"
info "8. しばらく放置しても ${B}画面が暗くならない${R}"
echo ""
echo "  ${YEL}1つでもダメだったら、次へ進まずにチャットへ報告してください。${R}"

finish_ok "  ${GREEN}インストールまで終わりました。${R}"
