package com.fire.adb.appservice.record;

import android.content.Context;
import android.graphics.Point;
import android.view.Display;
import android.view.WindowManager;

/** 真实分辨率和送进编码器的偶数尺寸。长边超过 1920 就缩小。 */
public final class DisplaySize {
    public final int realX;
    public final int realY;
    public final int encodedX;
    public final int encodedY;
    public final int dpi;

    public DisplaySize(int realX, int realY, int encodedX, int encodedY, int dpi) {
        this.realX = realX;
        this.realY = realY;
        this.encodedX = encodedX;
        this.encodedY = encodedY;
        this.dpi = dpi;
    }

    @SuppressWarnings("deprecation")
    public static DisplaySize read(Context context) {
        WindowManager manager = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
        Display display = manager.getDefaultDisplay();
        Point point = new Point();
        display.getRealSize(point);
        int x = even(point.x);
        int y = even(point.y);
        if (x < 2 || y < 2) {
            throw new IllegalStateException("display size unavailable");
        }
        int longEdge = Math.max(x, y);
        int encodedX = x;
        int encodedY = y;
        if (longEdge > 1920) {
            double scale = 1920.0 / longEdge;
            encodedX = even((int) (x * scale));
            encodedY = even((int) (y * scale));
        }
        android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
        display.getRealMetrics(metrics);
        int dpi = metrics.densityDpi > 0 ? metrics.densityDpi : 160;
        return new DisplaySize(x, y, encodedX, encodedY, dpi);
    }

    static int even(int value) {
        int sized = Math.max(value, 2);
        return sized & ~1;
    }
}
