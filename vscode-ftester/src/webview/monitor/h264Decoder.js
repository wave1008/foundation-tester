// H.264 Annex-B チャンク→WebCodecs VideoDecoder→canvas 描画。
// 契約(呼び出し元: deviceTiles.js/liveTab.js): pushChunk は初回キーフレーム受信まで delta を破棄し、
// 初回キーフレームの SPS(NAL type 7)から codec 文字列を組み立てて configure する
// (description は渡さない= Annex-B 入力として扱われる)。configure 完了までに届いたチャンクは
// デコード順を保つためキューに溜め、resolve 後にまとめて decode する。
// onError は非対応/例外/decoder エラーのいずれでも高々1回だけ発火し、以後 pushChunk は無視する
// (呼び出し元は onError を受けたら dispose して再生成しないこと)。

const DRAW_INTERVAL_MS = 66; // 描画間引き(~15fps)。デコードは全チャンク行う(Pフレーム連鎖のため間引けない)。

// data は「SPS+PPS+IDR 連結済みの Annex-B」前提(先頭付近に SPS がある想定でスキャン)。
// SPS の profile_idc/constraint_flags/level_idc(NAL ヘッダ直後の3バイト)から codec 文字列を作る。
function findAvcCodecString(data) {
  for (let i = 0; i + 3 < data.length; i++) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      const nalStart = i + 3;
      if ((data[nalStart] & 0x1f) === 7 && nalStart + 3 < data.length) {
        const hex = (b) => b.toString(16).padStart(2, '0');
        return 'avc1.' + hex(data[nalStart + 1]) + hex(data[nalStart + 2]) + hex(data[nalStart + 3]);
      }
    }
  }
  return null;
}

// onFrameRendered(省略可): canvas へ 1 フレーム描画するたびに呼ぶ(描画間引き後=最大 ~15fps)。
// deviceTiles.js がポーリング抑止の streamRendered ack に使う(liveTab.js は未使用)。
export function createH264Renderer({ canvas, onError, onFirstFrame, onFrameRendered }) {
  const ctx = canvas.getContext('2d');
  let decoder = null;
  let state = 'idle'; // idle -> configuring -> ready、または errored/disposed で以後何もしない
  let sawKeyframe = false;
  let pendingChunks = []; // configuring 中に届いたチャンク(decode 順を保つため到着順を維持)
  let sized = false; // pushChunk 引数の width/height によるキャンバス事前サイズは初回のみ
  let errorSent = false;
  let firstFrameSent = false;
  let lastDrawTime = -Infinity;

  function fail() {
    if (errorSent) {
      return;
    }
    errorSent = true;
    state = 'errored';
    onError();
  }

  function decodeNow(chunk) {
    try {
      decoder.decode(chunk);
    } catch {
      fail();
    }
  }

  function flushPending() {
    const queued = pendingChunks;
    pendingChunks = [];
    for (const chunk of queued) {
      decodeNow(chunk);
    }
  }

  function configure(spsData) {
    const codec = findAvcCodecString(spsData);
    if (!codec) {
      fail();
      return;
    }
    state = 'configuring';
    let supportPromise;
    try {
      supportPromise = VideoDecoder.isConfigSupported({ codec, optimizeForLatency: true });
    } catch {
      fail();
      return;
    }
    supportPromise
      .then((support) => {
        if (state !== 'configuring') {
          return; // dispose/fail が先に走った(decoder は既に close 済みの可能性がある)
        }
        if (!support || !support.supported) {
          fail();
          return;
        }
        try {
          decoder.configure({ codec, optimizeForLatency: true });
        } catch {
          fail();
          return;
        }
        state = 'ready';
        flushPending();
      })
      .catch(() => fail());
  }

  function handleFrame(frame) {
    const now = performance.now();
    if (now - lastDrawTime < DRAW_INTERVAL_MS) {
      frame.close();
      return;
    }
    lastDrawTime = now;
    try {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
    } finally {
      frame.close();
    }
    if (!firstFrameSent) {
      firstFrameSent = true;
      onFirstFrame({ width: frame.displayWidth, height: frame.displayHeight });
    }
    if (onFrameRendered) {
      onFrameRendered();
    }
  }

  function pushChunk(data, keyframe, width, height) {
    if (state === 'errored' || state === 'disposed') {
      return;
    }
    if (typeof VideoDecoder === 'undefined') {
      fail();
      return;
    }
    if (!sawKeyframe) {
      if (!keyframe) {
        return; // 初回キーフレーム前の delta は破棄
      }
      sawKeyframe = true;
    }
    if (!decoder) {
      decoder = new VideoDecoder({ output: handleFrame, error: () => fail() });
    }
    if (width > 0 && height > 0 && !sized) {
      canvas.width = width;
      canvas.height = height;
      sized = true;
    }
    const chunk = new EncodedVideoChunk({
      type: keyframe ? 'key' : 'delta',
      timestamp: Math.round(performance.now() * 1000),
      data,
    });
    if (state === 'idle') {
      configure(data);
      pendingChunks.push(chunk);
      return;
    }
    if (state === 'configuring') {
      pendingChunks.push(chunk);
      return;
    }
    decodeNow(chunk);
  }

  function dispose() {
    state = 'disposed';
    pendingChunks = [];
    if (decoder) {
      try {
        decoder.close();
      } catch {
        // 既に closed 等は無視してよい
      }
      decoder = null;
    }
  }

  return { pushChunk, dispose };
}
