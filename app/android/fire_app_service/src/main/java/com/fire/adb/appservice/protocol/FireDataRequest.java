package com.fire.adb.appservice.protocol;

import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;

/** 桌面端发来的一条请求。 */
public final class FireDataRequest {
    public final String name;
    public final String type;
    public final int id;
    private final byte[] body;

    FireDataRequest(String name, String type, int id, byte[] body) {
        this.name = name;
        this.type = type;
        this.id = id;
        this.body = body == null ? new byte[0] : body;
    }

    public String text() {
        return new String(body, StandardCharsets.UTF_8);
    }

    public JSONObject json() throws JSONException {
        if (body.length == 0) {
            return new JSONObject();
        }
        return new JSONObject(text());
    }

    String display() {
        return FireDataCodec.display(name, type, id, body);
    }
}
