package com.fire.adb.appservice.protocol;

import android.util.Log;

import java.io.IOException;
import java.io.InputStream;

/** 从标准输入读出 {@link FireDataRequest}。读完整条后打印，再交给调用方。 */
public final class FireDataReader {
    private static final String TAG = "FireAdb";

    private final InputStream in;

    public FireDataReader(InputStream in) {
        this.in = in;
    }

    /** 流结束时返回 null。读到一半就结束则抛出。 */
    public FireDataRequest read() throws IOException {
        FireDataCodec.Decoded decoded = FireDataCodec.read(in);
        if (decoded == null) {
            return null;
        }
        FireDataRequest request = new FireDataRequest(
                decoded.name, decoded.type, decoded.id, decoded.body);
        Log.i(TAG, "请求 " + request.display());
        return request;
    }
}
