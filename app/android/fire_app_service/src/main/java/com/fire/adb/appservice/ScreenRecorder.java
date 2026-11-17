package com.fire.adb.appservice;

import android.content.Context;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Looper;
import android.view.Surface;

import com.fire.adb.appservice.record.DisplayMirror;
import com.fire.adb.appservice.record.DisplaySize;
import com.fire.adb.appservice.record.Mp4Writer;
import com.fire.adb.appservice.record.PlaybackAudio;
import com.fire.adb.appservice.record.RecordCodecs;
import com.fire.adb.appservice.record.RecordStop;
import com.fire.adb.appservice.util.LogUtils;
import com.fire.adb.appservice.record.SurfaceControlMirror;
import com.fire.adb.appservice.record.VirtualDisplayMirror;
import com.fire.adb.appservice.util.AndroidContexts;

import java.io.File;

/**
 * 辅助服务里的录屏入口。以 shell 身份运行，把 mp4 写到给定路径。
 *
 * <pre>
 * app_process / com.fire.adb.appservice.ScreenRecorder --output 路径 --time-limit 秒
 * </pre>
 *
 * {@code --time-limit 0} 表示不限时。停止时由桌面端创建
 * {@code /data/local/tmp/fireadb_rec.stop}，这里写完索引再退出。
 * 画面由 {@link VirtualDisplayMirror} 或 {@link SurfaceControlMirror} 送进编码器。
 * 声音由 {@link PlaybackAudio} 采集，样本由 {@link Mp4Writer} 封装。
 * 前一种画面没有帧就换下一种。采不到声音就只留画面。
 */
public final class ScreenRecorder {
    static final String STOP_PATH = RecordStop.STOP_PATH;
    private static final String MIME = "video/avc";
    private static final int BITRATE = 8000000;
    private static final int FRAME_RATE = 30;
    private static final long FIRST_FRAME_NS = 2500000000L;
    private static final long DRAIN_NS = 2000000000L;

    private ScreenRecorder() {}

    public static void main(String[] args) {
        Throwable last = null;
        try {
            Arguments arguments = Arguments.parse(args);
            if (Looper.myLooper() == null) {
                Looper.prepareMainLooper();
            }
            Context context = AndroidContexts.system();
            DisplaySize display = DisplaySize.read(context);
            RecordStop watch = new RecordStop(arguments.timeLimitSec);
            String[] methods = new String[] {"virtual", "surface"};
            for (int i = 0; i < methods.length; i++) {
                if (watch.requested()) {
                    break;
                }
                String method = methods[i];
                try {
                    LogUtils.i("try " + method);
                    boolean saved = recordSurface(method, context, arguments.output, display, watch);
                    if (saved) {
                        LogUtils.i("use " + method);
                        System.exit(0);
                    }
                    if (watch.requested()) {
                        break;
                    }
                    LogUtils.i("skip " + method + ": no frames");
                } catch (Throwable error) {
                    last = LogUtils.unwrap(error);
                    LogUtils.e("skip " + method, error);
                }
            }
        } catch (Throwable error) {
            last = LogUtils.unwrap(error);
            LogUtils.e("failed", error);
            System.exit(1);
        }
        LogUtils.e("failed", last == null ? new IllegalStateException("no frames") : last);
        System.exit(1);
    }

    private static boolean recordSurface(
            String method,
            Context context,
            String output,
            DisplaySize display,
            RecordStop watch) throws Exception {
        MediaCodec codec = MediaCodec.createEncoderByType(MIME);
        DisplayMirror mirror = null;
        Mp4Writer writer = null;
        PlaybackAudio audio = null;
        boolean saved = false;
        try {
            MediaFormat format = videoFormat(display.encodedX, display.encodedY, BITRATE);
            format.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            Surface surface = codec.createInputSurface();
            codec.start();
            writer = new Mp4Writer(output, codec);
            audio = PlaybackAudio.tryStart(context, writer);
            mirror = "virtual".equals(method)
                    ? new VirtualDisplayMirror()
                    : new SurfaceControlMirror();
            mirror.start(context, surface, display);
            long firstDeadline = System.nanoTime() + FIRST_FRAME_NS;
            boolean eosSent = false;
            long drainDeadline = 0L;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (true) {
                boolean stop = watch.requested();
                if (!writer.wrote && !stop && System.nanoTime() > firstDeadline) {
                    return false;
                }
                if (stop && writer.wrote && !eosSent) {
                    codec.signalEndOfInputStream();
                    eosSent = true;
                    drainDeadline = System.nanoTime() + DRAIN_NS;
                }
                if (stop && !writer.wrote) {
                    return false;
                }
                int index = codec.dequeueOutputBuffer(info, 50000);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (eosSent && System.nanoTime() > drainDeadline) {
                        break;
                    }
                    continue;
                }
                if (index < 0) {
                    writer.onFormat(index);
                    continue;
                }
                boolean eos = writer.write(index, info);
                if (eos) {
                    break;
                }
            }
            if (!writer.wrote) {
                return false;
            }
            if (audio != null) {
                audio.end();
            }
            writer.finish();
            saved = true;
            return true;
        } finally {
            if (audio != null) {
                audio.release();
            }
            if (mirror != null) {
                mirror.release();
            }
            if (writer != null) {
                writer.release();
            } else {
                RecordCodecs.release(codec);
            }
            if (!saved) {
                new File(output).delete();
            }
        }
    }

    private static MediaFormat videoFormat(int width, int height, int bitrate) {
        MediaFormat format = MediaFormat.createVideoFormat(MIME, width, height);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        return format;
    }

    private static final class Arguments {
        final String output;
        final int timeLimitSec;

        Arguments(String output, int timeLimitSec) {
            this.output = output;
            this.timeLimitSec = timeLimitSec;
        }

        static Arguments parse(String[] args) {
            String output = null;
            int limit = 180;
            for (int i = 0; i < args.length; i++) {
                if ("--output".equals(args[i]) && i + 1 < args.length) {
                    output = args[++i];
                } else if ("--time-limit".equals(args[i]) && i + 1 < args.length) {
                    limit = Integer.parseInt(args[++i]);
                }
            }
            if (output == null || output.length() == 0) {
                throw new IllegalArgumentException("missing --output");
            }
            if (limit < 0) {
                limit = 0;
            }
            return new Arguments(output, limit);
        }
    }
}
