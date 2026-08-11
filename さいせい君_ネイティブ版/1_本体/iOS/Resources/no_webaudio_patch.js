/* ============================================================
   v.in04「息継ぎ消し」パッチ
   2026-08-11 くろ

   ★ このファイルは saisei_v32.html を 1 文字も書き換えないための仕掛け。
     アプリ側（WebScreen.swift）が、HTML を読み終わった直後にこれを流し込む。
     いらなくなったら、このファイルを消して WebScreen.swift の
     「パッチを流し込む」ところを外すだけで、完全に元へ戻る。

   ★ なぜこれを作ったか（0_仕様/決定と教訓_これまで全部.md 第4章）

     ・息継ぎ（再生開始から約0.5秒後に0.272秒ぶん巻き戻る）の犯人は
       「<audio> を Web Audio に通していること」＝ createMediaElementSource。
       これを切ると巻き戻りは完全に消える（実機で確認済み）。

     ・しかし切ると音量が死ぬ、と紙に書いてある。その根拠は第2章2-2の
       「iOS Safari では <audio>.volume がプログラムから変更できない」。

     ★ ここが今回の賭けどころ。
       2026-08-11、アプリ（WKWebView）の中では「Safari の掟」が
       当てはまらない例が続けて2つ見つかった。
         ・file:// でも localStorage / IndexedDB が生きていた
         ・「触った瞬間しか読み込めない」掟は設定1行で外れていた
       ならば <audio>.volume も生きているかもしれない。
       生きていれば ── Web Audio を切るだけで、息継ぎが消えて音量も残る。

   ★ 元のコードが用意してくれていた逃げ道を使っている
     _buildSlots() には「createMediaElementSource に失敗したら素の<audio>で鳴らす」
     という保険が最初から書いてある。だからこのパッチは
     「createMediaElementSource をわざと失敗させる」だけでよく、
     音量の受け皿は元のコードがすでに持っている。

   ★ このパッチで分かっていて捨てているもの（正直に書く）
     1. 音量の上限が 1.5 → 1.0 になる。<audio>.volume は 0〜1 しか受け付けない
     2. 画面のスペクトラム（音に合わせて動く棒）が動かなくなる。
        アナライザーは Web Audio の途中に付いているため。波形の絵は無関係で残る
   ============================================================ */

(function () {
  'use strict';

  if (typeof PondashiAudioEngine === 'undefined') {
    console.warn('[v.in04] PondashiAudioEngine が見つからないのでパッチを当てません');
    return;
  }

  var P = PondashiAudioEngine.prototype;
  var master = 0.8;          // マスター音量（元の初期値と同じ）

  function clamp(v) {
    if (typeof v !== 'number' || !isFinite(v)) return 0;
    return Math.max(0, Math.min(1, v));
  }

  function toSwift(msg) {
    try { window.webkit.messageHandlers.saisei.postMessage(msg); } catch (e) {}
  }

  /* ---- 音量を時間をかけて動かす（Web Audio の代わりの坂） ---- */
  function rampVolume(inst, from, to, seconds, onDone) {
    if (inst.__rampTimer) { clearInterval(inst.__rampTimer); inst.__rampTimer = null; }
    var el = inst.el;
    var t0 = Date.now();
    var ms = Math.max(1, seconds * 1000);
    try { el.volume = clamp(from); } catch (e) {}
    inst.__rampTimer = setInterval(function () {
      var p = Math.min(1, (Date.now() - t0) / ms);
      try { el.volume = clamp(from + (to - from) * p); } catch (e) {}
      if (p >= 1) {
        clearInterval(inst.__rampTimer);
        inst.__rampTimer = null;
        if (typeof onDone === 'function') onDone();
      }
    }, 25);
  }

  /* ============================================================
     1) Web Audio 経路を切る ── これが息継ぎ対策の本体
     ============================================================ */
  var origBuildSlots = P._buildSlots;
  P._buildSlots = function () {
    var ctx = this.audioCtx;
    if (ctx && !ctx.__saiseiCut) {
      ctx.__saiseiCut = true;
      ctx.createMediaElementSource = function () {
        // 元のコードの catch に落として、素の <audio> で鳴らす道へ誘導する
        throw new Error('[v.in04] Web Audio 経路を意図的に切っています（息継ぎ対策）');
      };
    }
    this.webAudioRouteOK = false;
    return origBuildSlots.apply(this, arguments);
  };

  /* ============================================================
     2) マスター音量 ── 鳴っている音へ直に反映する
     ============================================================ */
  var origSetMaster = P.setMasterVolume;
  P.setMasterVolume = function (volume) {
    master = (typeof volume === 'number' && isFinite(volume)) ? volume : 0.8;
    try { origSetMaster.apply(this, arguments); } catch (e) {}
    for (var i = 0; i < 256; i++) {              // MAX_PADS = 256
      var list = this.activeSources[i];
      if (!list || !list.length) continue;
      var pad = this.pads[i];
      for (var k = 0; k < list.length; k++) {
        var inst = list[k];
        if (inst.gainNode || !inst.el || inst.isFadingOut) continue;
        try { inst.el.volume = clamp((pad ? pad.volume : 1) * master); } catch (e) {}
      }
    }
  };

  /* ============================================================
     3) パッドごとの音量（再生中のつまみ操作）
     ============================================================ */
  var origSetPadVolume = P.setPadVolume;
  P.setPadVolume = function (index, volume) {
    try { origSetPadVolume.apply(this, arguments); } catch (e) {}
    var list = this.activeSources[index];
    if (!list) return;
    for (var k = 0; k < list.length; k++) {
      var inst = list[k];
      if (inst.gainNode || !inst.el || inst.isFadingOut) continue;
      try { inst.el.volume = clamp(volume * master); } catch (e) {}
    }
  };

  /* ============================================================
     4) 再生 ── フェードインを自前でかける ＋ 音量が効くか1回だけ実測する
     ============================================================ */
  var origPlayPad = P.playPad;
  P.playPad = function (index, onPlayEnd) {
    var ok = origPlayPad.call(this, index, onPlayEnd);
    if (!ok) return ok;

    var pad = this.pads[index];
    var list = this.activeSources[index];
    if (!pad || !list || !list.length) return ok;

    var inst = list[list.length - 1];
    if (inst.gainNode || !inst.el) return ok;     // Web Audio が生きているなら触らない

    var target = clamp(pad.volume * master);

    /* ★★ 2026-08-11 削除した検査（同じ間違いを繰り返さないために残す）
       ここで「el.volume に 0.37 を書いて、読み返して 0.37 なら音量が効いている」
       という判定をしていた。実機では【○と表示されたのに、音は変わらなかった】。

       原因: iOS は volume を「書かせるし、読み返させる。ただし音には反映しない」。
       つまり ★読み返しでは絶対に検出できない★。耳でしか分からない。

       しかもこの答えは 0_仕様/決定と教訓_これまで全部.md 第2章2-2 に
       最初から書いてあった。くろは答えの出ている実験をやり直し、
       その上で壊れた計器を親分に信用させた。二度とやらない。 */

    if (pad.fadeIn > 0) {
      rampVolume(inst, 0, target, pad.fadeIn);
    } else {
      try { inst.el.volume = target; } catch (e) {}
    }
    return ok;
  };

  /* ============================================================
     5) 停止 ── フェードアウトを自前でかける
        （CrossFade が初期値なので、ここが無いと通常操作が壊れる）
     ============================================================ */
  var origStopPad = P.stopPad;
  P.stopPad = function (index, customFadeOutTime) {
    var list = this.activeSources[index];
    if (!list || !list.length) return origStopPad.apply(this, arguments);

    var pad = this.pads[index];
    var fadeOut = (customFadeOutTime !== null && customFadeOutTime !== undefined)
      ? customFadeOutTime
      : (pad ? pad.fadeOut : 0);

    var targets = [];
    for (var k = 0; k < list.length; k++) {
      var it = list[k];
      if (!it.gainNode && it.el && !it.stopping && !it.finished) targets.push(it);
    }

    // フェード不要、または Web Audio が生きているぶんは元の処理へ丸投げ
    if (!targets.length || !(fadeOut > 0)) return origStopPad.apply(this, arguments);

    var self = this;
    var ctxNow = this.audioCtx ? this.audioCtx.currentTime : 0;

    targets.forEach(function (inst) {
      inst.stopping = true;
      inst.isFadingOut = true;
      inst.fadeOutStartTime = ctxNow;              // 画面の FADE 表示がこれを見ている
      inst.fadeOutDuration = fadeOut;
      try { inst.el.loop = false; } catch (e) {}

      var from = 1;
      try { from = inst.el.volume; } catch (e) {}

      rampVolume(inst, from, 0, fadeOut, function () {
        try { self._finishInstance(index, inst); } catch (e) {}
        // 次に鳴らすときのために音量を戻しておく（v.in02 で学んだ後始末）
        var p = self.pads[index];
        try { inst.el.volume = clamp((p ? p.volume : 1) * master); } catch (e) {}
      });
    });

    // 元の stopPad は呼ばない（呼ぶと即座に止まってフェードが消える）
  };

  window.__saiseiPatch = 'v.in04 息継ぎ消し';
  console.log('[v.in04] 息継ぎ消しパッチを当てました');
})();
