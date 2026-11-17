package com.fire.adb.appservice.record;

import android.content.Context;
import android.view.Surface;

/** 把设备画面送进编码器的一种方式。 */
public interface DisplayMirror {
    void start(Context context, Surface surface, DisplaySize display) throws Exception;

    void release();
}
