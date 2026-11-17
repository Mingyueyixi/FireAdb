package com.fire.adb.appservice.image;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import com.fire.adb.appservice.protocol.CommandHandler;
import com.fire.adb.appservice.protocol.FireDataRequest;
import com.fire.adb.appservice.protocol.FireDataResponse;
import com.fire.adb.appservice.protocol.FireDataWriter;
import com.fire.adb.appservice.util.LogUtils;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.util.Locale;

/**
 * 文件列表的小图。{@code image.thumb} 的正文是路径，响应是 JPEG 字节。
 *
 * <p>调用方已经连在常驻服务上。这里只在当前进程里解码并缩小，不另起进程。
 * 长边大约 80 像素，质量 70。列表格子是 40，80 够两倍显示。
 * 解不出来就回错误，列表继续用图标。
 */
public final class ImageThumbProtocol implements CommandHandler {
    static final int EDGE = 80;
    static final int QUALITY = 70;
    static final long MAX_BYTES = 32L * 1024L * 1024L;

    private final FireDataWriter out;

    public ImageThumbProtocol(FireDataWriter out) {
        this.out = out;
    }

    @Override
    public boolean handle(FireDataRequest request) throws Exception {
        if (!"image.thumb".equals(request.name)) {
            return false;
        }
        try {
            JSONObject json = request.json();
            byte[] jpeg = render(json.optString("path", ""));
            out.send(FireDataResponse.bytes("image.thumb", request.id, jpeg));
        } catch (Exception error) {
            LogUtils.w("图片预览失败", error);
            out.send(FireDataResponse.error(request.id, String.valueOf(error.getMessage())));
        }
        return true;
    }

    static byte[] render(String path) {
        if (path == null || path.length() == 0 || path.indexOf('\0') >= 0) {
            throw new IllegalStateException("路径无效");
        }
        File file = new File(path);
        if (!file.isFile()) {
            throw new IllegalStateException("文件不存在");
        }
        if (!isImageName(file.getName())) {
            throw new IllegalStateException("不是图片");
        }
        if (file.length() > MAX_BYTES) {
            throw new IllegalStateException("图片过大");
        }
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(path, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw new IllegalStateException("无法识别图片");
        }
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight);
        Bitmap decoded = BitmapFactory.decodeFile(path, options);
        if (decoded == null) {
            throw new IllegalStateException("无法识别图片");
        }
        Bitmap scaled = scale(decoded);
        try {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            if (!scaled.compress(Bitmap.CompressFormat.JPEG, QUALITY, buffer)) {
                throw new IllegalStateException("无法压缩图片");
            }
            return buffer.toByteArray();
        } finally {
            scaled.recycle();
        }
    }

    static boolean isImageName(String name) {
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot >= name.length() - 1) {
            return false;
        }
        String extension = name.substring(dot + 1).toLowerCase(Locale.US);
        return "jpg".equals(extension)
                || "jpeg".equals(extension)
                || "png".equals(extension)
                || "webp".equals(extension)
                || "gif".equals(extension)
                || "bmp".equals(extension)
                || "heic".equals(extension)
                || "heif".equals(extension);
    }

    /** 长边落到大约 {@link #EDGE} 的 2 倍以内，再交给精确缩放。 */
    static int sampleSize(int width, int height) {
        int longest = Math.max(width, height);
        int sample = 1;
        while (longest / (sample * 2) >= EDGE && sample < 64) {
            sample *= 2;
        }
        return sample;
    }

    private static Bitmap scale(Bitmap source) {
        int width = source.getWidth();
        int height = source.getHeight();
        int longest = Math.max(width, height);
        if (longest <= EDGE) {
            return source;
        }
        float ratio = EDGE / (float) longest;
        int targetWidth = Math.max(1, Math.round(width * ratio));
        int targetHeight = Math.max(1, Math.round(height * ratio));
        Bitmap scaled = Bitmap.createScaledBitmap(source, targetWidth, targetHeight, true);
        if (scaled != source) {
            source.recycle();
        }
        return scaled;
    }
}
