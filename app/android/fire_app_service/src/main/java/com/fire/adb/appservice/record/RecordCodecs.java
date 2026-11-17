package com.fire.adb.appservice.record;

import android.media.MediaCodec;

public final class RecordCodecs {
    private RecordCodecs() {}

    public static void release(MediaCodec codec) {
        try {
            codec.stop();
        } catch (Throwable ignored) {
        }
        try {
            codec.release();
        } catch (Throwable ignored) {
        }
    }
}
