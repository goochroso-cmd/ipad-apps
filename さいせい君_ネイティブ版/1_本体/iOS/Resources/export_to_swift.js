/* ============================================================
   v.in05「曲の引っ越し」パッチ
   2026-08-11 くろ

   ★ このファイルがやることは、たった1つ。
     ブラウザの倉庫（IndexedDB）に入っている曲を、
     Swift 側（アプリの Documents フォルダ）へコピーする。

   ★ なぜ必要か
     Swift は IndexedDB の扉を開けられない。
     つまり曲を引っ越しさせないと、AVAudioPlayer は鳴らす物を1つも持っていない。
     紙（10章）の「窓口13個を差し替える」より前に、必ずここを越える必要がある。

   ★ この版では、音の本線はまだ Web のまま（v.in04 の状態）。
     引っ越しの速さと、Swift が本当に鳴らせるかを先に実機で測る。
     だから、この版で音が良くなることは何もない。それでいい。

   ★ HTML は 1 文字も触っていない。
     v.in04 と同じやり方（WKUserScript で外から流し込む）を踏襲。
     いらなくなったら、このファイルと WebScreen.swift の流し込みを消すだけで戻る。

   ★ 送り方（Air 2 を固めないための工夫）
     ・曲は1つずつ。同時に何本も送らない
     ・1曲も、256KB ずつの細切れにして送る
     ・1切れ送るたびに setTimeout(0) で画面に順番を譲る
       （まとめて送ると、その間ずっと画面が固まる＝本番事故のもと）

   ★ 2回目からは送らない
     Swift 側に同じ大きさのファイルが既にあれば、その曲は飛ばす。
     起動のたびに 140MB を流し直すようなことはしない。
   ============================================================ */

(function () {
  'use strict';

  if (typeof PondashiAudioEngine === 'undefined') {
    console.warn('[v.in05] PondashiAudioEngine が見つからないので引っ越しパッチを当てません');
    return;
  }

  var P = PondashiAudioEngine.prototype;

  var CHUNK = 256 * 1024;   // 生データで 256KB ずつ送る
  var MAX_PADS_SCAN = 256;  // 元コードの MAX_PADS と同じ

  var engineRef = null;     // engine の実体（loadAllPads の this から捕まえる）
  var vault = null;         // Swift 側にある物の一覧 { "7": 15234567, ... }
  var queue = [];           // 送る順番待ち
  var sending = false;
  var kicked = false;       // 引っ越しを開始したか（二重起動よけ）
  var t0 = 0;

  function toSwift(msg) {
    try { window.webkit.messageHandlers.saisei.postMessage(msg); } catch (e) {}
  }

  function log(s) {
    try { console.log('[v.in05] ' + s); } catch (e) {}
  }

  /* ------------------------------------------------------------
     Swift → JS の窓口
     ------------------------------------------------------------ */
  window.__saiseiVault = {
    /* Swift が「うちには今これが有る」と教えてくれる */
    onList: function (json) {
      try { vault = (typeof json === 'string') ? JSON.parse(json) : json; }
      catch (e) { vault = {}; }
      log('Swift 側の在庫: ' + JSON.stringify(vault));
      buildQueue();
      pump();
    }
  };

  /* ------------------------------------------------------------
     引っ越しの開始
     ------------------------------------------------------------ */
  function kick(engine) {
    if (kicked) return;
    kicked = true;
    engineRef = engine;
    t0 = Date.now();
    log('倉庫の読み出しが終わった。Swift に在庫を聞く');
    toSwift({ t: 'vaultAsk' });   // → Swift が __saiseiVault.onList を呼び返す
  }

  /* ------------------------------------------------------------
     いつ動き出すか ── ここは慎重に作ってある。理由を残す。

     ★ engine の実体は HTML の中では `let engine;`（4043行目）で持たれている。
       let は window にぶら下がらないので、パッチ側から window.engine では掴めない。
       だから「プロトタイプのどれかが呼ばれたときの this」を捕まえる。

     ★ このパッチが流し込まれるのは atDocumentEnd。
       HTML 側の DOMContentLoaded（4045行目）はそれより先に走っている可能性がある。
       つまり loadAllPads() は【パッチが当たる前に呼ばれ終わっているかもしれない】。
       それを当てにすると、起動の速さ次第で動いたり動かなかったりする不安定な作りになる。

     ★ そこで _applyCachedDurations() を目印にする。
       これは loadAllPads の【中】で、倉庫の読み出しが終わった後に呼ばれる
       （2867行目と2903行目の2箇所。どちらも読み出し完了の地点）。
       中から呼ばれるので、呼ばれる時刻は必ずパッチが当たった後になる。
     ------------------------------------------------------------ */

  /* engine の実体を捕まえるためだけの細工（動きは1つも変えていない） */
  var origHasAudio = P.hasAudio;
  P.hasAudio = function () {
    if (!engineRef) engineRef = this;
    return origHasAudio.apply(this, arguments);
  };

  /* ★ 本命の目印: 倉庫の読み出しが終わった地点 */
  var origApplyCached = P._applyCachedDurations;
  P._applyCachedDurations = function () {
    var self = this;
    var r = origApplyCached.apply(this, arguments);
    // 画面の描画を先に終わらせてから動き出す（起動を遅くしない）
    setTimeout(function () { kick(self); }, 1500);
    return r;
  };

  /* 念のための第二の目印（パッチが先に当たっていた場合はこちらも通る） */
  var origLoadAll = P.loadAllPads;
  P.loadAllPads = function () {
    var self = this;
    var r = origLoadAll.apply(this, arguments);
    Promise.resolve(r).then(function (v) {
      setTimeout(function () { kick(self); }, 1500);
      return v;
    }).catch(function () {});
    return r;
  };

  /* 保険: 30秒たっても目印が来なかったとき */
  setTimeout(function () {
    if (kicked) return;
    if (engineRef && engineRef.pads) {
      log('保険の経路で引っ越しを開始する');
      kick(engineRef);
    } else {
      log('engine が見つからないので引っ越しを見送る');
      toSwift({ t: 'vaultNone', why: 'engine が見つかりません（30秒待ちました）' });
    }
  }, 30000);

  /* ------------------------------------------------------------
     送るものを決める
     ------------------------------------------------------------ */
  function buildQueue() {
    queue = [];
    if (!engineRef || !engineRef.pads) { finish(); return; }

    var skipped = 0;
    for (var i = 0; i < MAX_PADS_SCAN; i++) {
      var pad = engineRef.pads[i];
      if (!pad) continue;
      if (!pad.audioBlob && pad.audioData) {
        try { engineRef._normalizeAudioSource(i); } catch (e) {}
        pad = engineRef.pads[i];
      }
      if (!pad || !pad.audioBlob || !pad.audioBlob.size) continue;

      var have = vault ? vault[String(i)] : undefined;
      if (have === pad.audioBlob.size) { skipped++; continue; }   // もう有る

      queue.push({
        index: i,
        blob: pad.audioBlob,
        name: pad.name || ('パッド ' + (i + 1)),
        mime: pad.mimeType || pad.audioBlob.type || 'audio/mpeg'
      });
    }

    log('送る曲 ' + queue.length + '件 ／ もう有るので飛ばす ' + skipped + '件');
    toSwift({ t: 'vaultPlan', send: queue.length, skip: skipped });
  }

  /* ------------------------------------------------------------
     1曲ずつ、細切れにして送る
     ------------------------------------------------------------ */
  function pump() {
    if (sending) return;
    var job = queue.shift();
    if (!job) { finish(); return; }
    sending = true;
    sendOne(job, function () {
      sending = false;
      setTimeout(pump, 0);
    });
  }

  function sendOne(job, done) {
    var blob = job.blob;
    var pos = 0;
    var seq = 0;

    toSwift({ t: 'vaultBegin', i: job.index, size: blob.size, name: job.name, mime: job.mime });

    function next() {
      if (pos >= blob.size) {
        toSwift({ t: 'vaultEnd', i: job.index });
        done();
        return;
      }
      var end = Math.min(pos + CHUNK, blob.size);
      var slice = blob.slice(pos, end);
      var fr = new FileReader();

      fr.onload = function () {
        var s = String(fr.result || '');
        var c = s.indexOf(',');
        toSwift({ t: 'vaultChunk', i: job.index, seq: seq, b64: (c >= 0 ? s.slice(c + 1) : '') });
        pos = end;
        seq++;
        // ★ ここで必ず画面に順番を譲る。詰めて送ると Air 2 が固まる
        setTimeout(next, 0);
      };

      fr.onerror = function () {
        toSwift({ t: 'vaultFail', i: job.index, msg: '曲の読み取りに失敗しました' });
        done();
      };

      try { fr.readAsDataURL(slice); }
      catch (e) {
        toSwift({ t: 'vaultFail', i: job.index, msg: String(e) });
        done();
      }
    }

    next();
  }

  function finish() {
    toSwift({ t: 'vaultAllDone', ms: Date.now() - t0 });
    log('引っ越し完了 ' + (Date.now() - t0) + 'ミリ秒');
  }

  /* ------------------------------------------------------------
     これから登録される曲も、Swift へコピーを1本渡す
     （紙 9.7章「1番（採用）」の中身）
     ------------------------------------------------------------ */
  var origImport = P.importFileToPad;
  P.importFileToPad = function (index, file) {
    var self = this;
    var r = origImport.apply(this, arguments);
    Promise.resolve(r).then(function (v) {
      // ★ すぐに送らない。
      //   iOS は「人が触った、まさにその瞬間」しか曲の読み込みを始めない。
      //   登録直後は armPad が読み込みの最中なので、そこへ割り込むと
      //   紙が5ヶ月追いかけた「準備中…で固まる」を自分で再発させてしまう。
      //   読み込みが落ち着くまで待ってからコピーを始める。
      setTimeout(function () {
        var pad = self.pads[index];
        if (!pad || !pad.audioBlob || !pad.audioBlob.size) return;
        engineRef = engineRef || self;
        queue.push({
          index: index,
          blob: pad.audioBlob,
          name: pad.name || ('パッド ' + (index + 1)),
          mime: pad.mimeType || pad.audioBlob.type || 'audio/mpeg'
        });
        t0 = Date.now();
        pump();
      }, 5000);
      return v;
    }).catch(function () {});
    return r;
  };

  window.__saiseiExport = 'v.in05 曲の引っ越し';
  log('引っ越しパッチを当てました');
})();
