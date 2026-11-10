package com.fire.adb.appservice.protocol;

import org.json.JSONObject;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** 设备端发出的一条响应。正文格式由 type 表达：json、bytes、text、html、none。 */
public final class FireDataResponse {
    public final String name;
    private final String type;
    private final int id;
    private final byte[] body;

    private FireDataResponse(String name, String type, int id, byte[] body) {
        this.name = name;
        this.type = type;
        this.id = id;
        this.body = body == null ? new byte[0] : body;
    }

    public static FireDataResponse none(String name, int id) {
        return new FireDataResponse(name, "none", id, new byte[0]);
    }

    public static FireDataResponse text(String name, int id, String text) {
        byte[] body = text == null ? new byte[0] : text.getBytes(StandardCharsets.UTF_8);
        return new FireDataResponse(name, body.length == 0 ? "none" : "text", id, body);
    }

    public static FireDataResponse json(String name, int id, JSONObject json) {
        return json(name, id, json == null ? "{}" : json.toString());
    }

    public static FireDataResponse json(String name, int id, String json) {
        byte[] body = json == null ? new byte[0] : json.getBytes(StandardCharsets.UTF_8);
        return new FireDataResponse(name, "json", id, body);
    }

    public static FireDataResponse bytes(String name, int id, byte[] body) {
        return new FireDataResponse(name, "bytes", id, body);
    }

    public static FireDataResponse error(int id, String message) {
        return text("session.error", id, message == null ? "" : message);
    }

    public static FireDataResponse done(int id) {
        return text("session.done", id, "ok");
    }

    byte[] header() throws IOException {
        return FireDataCodec.header(name, type, id, body.length);
    }

    byte[] body() {
        return body;
    }

    String display() {
        return FireDataCodec.display(name, type, id, body);
    }
}
