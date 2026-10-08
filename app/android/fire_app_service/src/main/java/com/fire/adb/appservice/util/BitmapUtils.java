package com.fire.adb.appservice.util;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;

import java.io.ByteArrayOutputStream;

/** 把 {@link Drawable} 画成指定宽高的软件位图，或按格式压缩成字节。 */
public final class BitmapUtils {
    private BitmapUtils() {}

    /**
     * 返回的位图宽高就是传入的宽高，由调用方 {@code recycle}。
     * 有固有宽高时先按固有宽高绘制，没有就按目标宽高绘制。尺寸不一致时缩放后再返回。
     */
    public static Bitmap drawableToBitmap(Drawable drawable, int width, int height) {
        if (drawable == null || width <= 0 || height <= 0) {
            return null;
        }
        Bitmap drawn = draw(drawable.getCurrent(), width, height);
        if (drawn == null) {
            return null;
        }
        if (drawn.getWidth() == width && drawn.getHeight() == height) {
            return drawn;
        }
        Bitmap scaled = Bitmap.createScaledBitmap(drawn, width, height, true);
        if (scaled != drawn) {
            drawn.recycle();
        }
        return scaled;
    }

    /**
     * 画成指定宽高后按 {@code format} 压缩。没有像素、绘制失败或压缩失败时返回空数组。
     * {@code quality} 为 0–100；PNG 会忽略它。
     */
    public static byte[] compress(
            Drawable drawable,
            int width,
            int height,
            Bitmap.CompressFormat format,
            int quality) {
        Bitmap bitmap = drawableToBitmap(drawable, width, height);
        if (bitmap == null) {
            return new byte[0];
        }
        try {
            if (!hasPixel(bitmap)) {
                return new byte[0];
            }
            return compress(bitmap, format, quality);
        } finally {
            bitmap.recycle();
        }
    }

    /** 按 {@code format} 压缩。位图仍由调用方回收。失败时返回空数组。 */
    public static byte[] compress(Bitmap bitmap, Bitmap.CompressFormat format, int quality) {
        if (bitmap == null || format == null) {
            return new byte[0];
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (!bitmap.compress(format, quality, out)) {
            return new byte[0];
        }
        return out.toByteArray();
    }

    private static Bitmap draw(Drawable drawable, int targetWidth, int targetHeight) {
        if (drawable instanceof BitmapDrawable) {
            Bitmap source = ((BitmapDrawable) drawable).getBitmap();
            Bitmap software = softwareBitmap(source);
            if (software != null) {
                return software;
            }
        }
        int width = drawable.getIntrinsicWidth();
        int height = drawable.getIntrinsicHeight();
        if (width <= 0) {
            width = targetWidth;
        }
        if (height <= 0) {
            height = targetHeight;
        }
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, canvas.getWidth(), canvas.getHeight());
            drawable.draw(canvas);
            return bitmap;
        } catch (Throwable error) {
            bitmap.recycle();
            return null;
        }
    }

    /** 复制成调用方可以回收的 {@code ARGB_8888}，不把 Drawable 自己的位图交出去。 */
    private static Bitmap softwareBitmap(Bitmap source) {
        if (source == null || source.isRecycled()) {
            return null;
        }
        return source.copy(Bitmap.Config.ARGB_8888, false);
    }

    private static boolean hasPixel(Bitmap bitmap) {
        int width = bitmap.getWidth();
        int height = bitmap.getHeight();
        int[] row = new int[width];
        for (int y = 0; y < height; y++) {
            bitmap.getPixels(row, 0, width, 0, y, width, 1);
            for (int x = 0; x < width; x++) {
                if ((row[x] >>> 24) != 0) {
                    return true;
                }
            }
        }
        return false;
    }
}
