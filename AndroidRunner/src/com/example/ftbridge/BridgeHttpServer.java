// BridgeHttpServer.java
// 依存ゼロのハンドロール HTTP/1.1 サーバ(Runner/FTesterRunnerUITests/BridgeHTTPServer.swift の Java 版)。
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
        final String path;
        final byte[] body;
        Request(String method, String path, byte[] body) {
            this.method = method;
            this.path = path;
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

    private BridgeHttpServer() {}

    /** accept ループ(ブロッキング)。ソケット生成失敗時のみ戻る */
    static void run(int port, Handler handler) {
        try (ServerSocket server = new ServerSocket(port, 16, InetAddress.getLoopbackAddress())) {
            while (true) {
                try (Socket sock = server.accept()) {
                    Request request = readRequest(sock.getInputStream());
                    Response response;
                    if (request == null) {
                        response = Response.error(400, "リクエストを解析できません");
                    } else {
                        try {
                            response = handler.handle(request);
                        } catch (Exception e) {
                            Log.e(BridgeInstrumentation.TAG, "handler failed", e);
                            response = Response.error(500, "bridge exception: " + e);
                        }
                    }
                    writeResponse(sock.getOutputStream(), response);
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

        int contentLength = 0;
        for (String line : lines) {
            int colon = line.indexOf(':');
            if (colon > 0 && line.substring(0, colon).equalsIgnoreCase("Content-Length")) {
                contentLength = Integer.parseInt(line.substring(colon + 1).trim());
            }
        }
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        int bodyStart = headerEnd + 4;
        body.write(all, bodyStart, all.length - bodyStart);
        while (body.size() < contentLength) {
            int n = in.read(chunk);
            if (n <= 0) break;
            body.write(chunk, 0, n);
        }
        return new Request(requestLine[0], requestLine[1], body.toByteArray());
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
