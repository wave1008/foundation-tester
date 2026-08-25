// BridgeHttpServer.java
// 依存ゼロのハンドロール HTTP/1.1 サーバ(Runner/FleetestRunnerUITests/BridgeHTTPServer.swift の Java 版)。
// 1接続ずつ逐次処理、Connection: close、Content-Length ボディのみ対応。
package com.example.ftbridge;

import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

final class BridgeHttpServer {

    static final class Request {
        final String method;
        /** クエリ文字列を含まない(BridgeRouter の完全一致 switch がクエリ違いで割れないため) */
        final String path;
        /** "?" 以降の生文字列("?" 自体は含まない)。無ければ空文字。パースは呼び出し側の責務 */
        final String query;
        final byte[] body;
        Request(String method, String path, String query, byte[] body) {
            this.method = method;
            this.path = path;
            this.query = query;
            this.body = body;
        }
    }

    static final class Response {
        final int status;
        final String contentType;
        final byte[] body;
        Response(int status, String contentType, byte[] body) {
            this.status = status;
            this.contentType = contentType;
            this.body = body;
        }
        static Response json(int status, String json) {
            return new Response(status, "application/json", json.getBytes(StandardCharsets.UTF_8));
        }
        static Response error(int status, String message) {
            org.json.JSONObject o = new org.json.JSONObject();
            try {
                o.put("error", message);
            } catch (org.json.JSONException ignored) {
            }
            return Response.json(status, o.toString());
        }
        static Response png(byte[] data) {
            return new Response(200, "image/png", data);
        }
    }

    interface Handler {
        Response handle(Request request);
    }

    /** 直前のリクエストまでの無通信秒数(/status の idleSeconds 申告用。accept 時に更新) */
    static volatile double lastIdleSeconds;

    private BridgeHttpServer() {}

    /** accept ループ(ブロッキング)。TTL 満了かソケット生成失敗で戻る(呼び出し元が exit する)。
     *  ttlSeconds: 無通信の上限秒。0 以下 = 無期限。心拍は全リクエスト(パース失敗も含む)。
     *  時刻は elapsedRealtime(単調クロック。壁時計の NTP ジャンプで誤爆させない)。 */
    static void run(int port, int ttlSeconds, Handler handler) {
        try (ServerSocket server = new ServerSocket(port, 16, InetAddress.getLoopbackAddress())) {
            // accept を定期的に起こして idle を判定する(単一スレッドなので排他不要)
            server.setSoTimeout(60_000);
            long lastRequestMillis = android.os.SystemClock.elapsedRealtime();
            while (true) {
                if (ttlSeconds > 0) {
                    long idleMillis = android.os.SystemClock.elapsedRealtime() - lastRequestMillis;
                    if (idleMillis > ttlSeconds * 1000L) {
                        Log.i(BridgeInstrumentation.TAG,
                                "bridge idle " + (idleMillis / 1000) + "s > ttl " + ttlSeconds
                                + "s; self-terminating");
                        return;
                    }
                }
                Socket accepted;
                try {
                    accepted = server.accept();
                } catch (java.net.SocketTimeoutException e) {
                    // 定期起床(soTimeout)。TTL 判定に戻るだけの正常経路なのでログしない。
                    // 下の受信タイムアウト(15s・異常系でログする)と混ぜないため accept だけ分ける
                    continue;
                }
                lastIdleSeconds =
                        (android.os.SystemClock.elapsedRealtime() - lastRequestMillis) / 1000.0;
                lastRequestMillis = android.os.SystemClock.elapsedRealtime();
                try (Socket sock = accepted) {
                    // 相手が Content-Length 分を送り切らずに待つと、単スレッドの accept ループが
                    // read で無限ブロックしブリッジ全体が wedge する。受信タイムアウトで離脱させる(15s)。
                    sock.setSoTimeout(15000);
                    // 計測: accept からの経過を段ごとに出す。ホスト側 actionMs との差が
                    // 「ブリッジの外(HTTP クライアント・接続確立・単一スレッドの待ち行列)」の量
                    long acceptedAt = android.os.SystemClock.uptimeMillis();
                    Request request = readRequest(sock.getInputStream());
                    long readAt = android.os.SystemClock.uptimeMillis();
                    Response response;
                    if (request == null) {
                        response = Response.error(400, "cannot parse the request");
                    } else {
                        try {
                            response = handler.handle(request);
                        } catch (Exception e) {
                            Log.e(BridgeInstrumentation.TAG, "handler failed", e);
                            response = Response.error(500, "bridge exception: " + e);
                        }
                    }
                    long handledAt = android.os.SystemClock.uptimeMillis();
                    writeResponse(sock.getOutputStream(), response);
                    if (BridgeInstrumentation.timingEnabled && request != null
                            && "POST".equals(request.method) && "/tap".equals(request.path)) {
                        Log.i(BridgeInstrumentation.TAG, "reqTiming " + request.path
                                + " read=" + (readAt - acceptedAt)
                                + " handle=" + (handledAt - readAt)
                                + " write=" + (android.os.SystemClock.uptimeMillis() - handledAt));
                    }
                } catch (Exception e) {
                    Log.e(BridgeInstrumentation.TAG, "connection failed", e);
                }
            }
        } catch (Exception e) {
            Log.e(BridgeInstrumentation.TAG, "server socket died", e);
        }
    }

    private static Request readRequest(InputStream in) throws Exception {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int headerEnd = -1;
        byte[] chunk = new byte[65536];
        while (headerEnd < 0) {
            int n = in.read(chunk);
            if (n <= 0) return null;
            buf.write(chunk, 0, n);
            headerEnd = indexOfHeaderEnd(buf.toByteArray());
            if (buf.size() > 4 * 1024 * 1024) return null;
        }
        byte[] all = buf.toByteArray();
        String header = new String(all, 0, headerEnd, StandardCharsets.UTF_8);
        String[] lines = header.split("\r\n");
        String[] requestLine = lines[0].split(" ");
        if (requestLine.length < 2) return null;
        // "/snapshot?refresh=1" → path="/snapshot" (switch が完全一致するため) / query="refresh=1"
        String rawTarget = requestLine[1];
        int queryStart = rawTarget.indexOf('?');
        String path = queryStart >= 0 ? rawTarget.substring(0, queryStart) : rawTarget;
        String query = queryStart >= 0 ? rawTarget.substring(queryStart + 1) : "";

        int contentLength = 0;
        for (String line : lines) {
            int colon = line.indexOf(':');
            if (colon > 0 && line.substring(0, colon).equalsIgnoreCase("Content-Length")) {
                try {
                    contentLength = Integer.parseInt(line.substring(colon + 1).trim());
                } catch (NumberFormatException e) {
                    contentLength = 0;  // iOS の Int(...) ?? 0 と同じ寛容化(throw で接続を落とさない)
                }
            }
        }
        // 過大/不正な Content-Length は無制限メモリ確保・長時間読取の的になるため弾く(不正=null→400)。
        if (contentLength < 0 || contentLength > 8 * 1024 * 1024) return null;
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        int bodyStart = headerEnd + 4;
        body.write(all, bodyStart, all.length - bodyStart);
        while (body.size() < contentLength) {
            int n = in.read(chunk);
            if (n <= 0) break;
            body.write(chunk, 0, n);
        }
        return new Request(requestLine[0], path, query, body.toByteArray());
    }

    private static int indexOfHeaderEnd(byte[] data) {
        for (int i = 0; i + 3 < data.length; i++) {
            if (data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n') {
                return i;
            }
        }
        return -1;
    }

    private static void writeResponse(OutputStream out, Response response) throws Exception {
        String statusText;
        switch (response.status) {
            case 200: statusText = "OK"; break;
            case 400: statusText = "Bad Request"; break;
            case 404: statusText = "Not Found"; break;
            case 409: statusText = "Conflict"; break;
            default: statusText = "Internal Server Error"; break;
        }
        String head = "HTTP/1.1 " + response.status + " " + statusText + "\r\n"
                + "Content-Type: " + response.contentType + "\r\n"
                + "Content-Length: " + response.body.length + "\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.UTF_8));
        out.write(response.body);
        out.flush();
    }
}
