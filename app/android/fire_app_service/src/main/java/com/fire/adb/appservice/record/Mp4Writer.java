package com.fire.adb.appservice.record;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.MediaMuxer;

import java.nio.ByteBuffer;

/** 把视频和音频样本按同一时间轴写进 mp4。 */
public final class Mp4Writer {
    private final String path;
    private final MediaCodec codec;
    private final Object lock = new Object();
    private final java.util.ArrayList<PendingSample> pending =
            new java.util.ArrayList<PendingSample>();
    private MediaMuxer muxer;
    private MediaFormat videoFormat;
    private MediaFormat audioFormat;
    private int videoTrack = -1;
    private int audioTrack = -1;
    private boolean audioEnabled;
    private boolean started;
    public volatile boolean wrote;
    private long lastVideoPts = -1L;
    private long lastAudioPts = -1L;
    private long videoOrigin = -1L;

    public Mp4Writer(String path, MediaCodec codec) {
        this.path = path;
        this.codec = codec;
        new java.io.File(path).delete();
    }

    public void enableAudio() {
        synchronized (lock) {
            audioEnabled = true;
        }
    }

    public void addAudioFormat(MediaFormat format) {
        synchronized (lock) {
            if (audioFormat != null || !audioEnabled || started) {
                return;
            }
            audioFormat = format;
            startIfReady();
        }
    }

    public void abandonAudio() {
        synchronized (lock) {
            if (started || !audioEnabled) {
                return;
            }
            audioEnabled = false;
            audioFormat = null;
            startIfReady();
        }
    }

    public void onFormat(int index) throws java.io.IOException {
        if (index != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            return;
        }
        synchronized (lock) {
            if (videoFormat != null) {
                throw new IllegalStateException("encoder format changed twice");
            }
            videoFormat = codec.getOutputFormat();
            startIfReady();
        }
    }

    public boolean write(int index, MediaCodec.BufferInfo info) {
        boolean eos;
        synchronized (lock) {
            eos = acceptVideo(index, info);
        }
        codec.releaseOutputBuffer(index, false);
        return eos;
    }

    public boolean acceptAudio(ByteBuffer buffer, MediaCodec.BufferInfo info) {
        synchronized (lock) {
            boolean sample = info.size > 0
                    && buffer != null
                    && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
            if (sample && (audioEnabled || audioTrack >= 0)) {
                long pts = monotonic(info.presentationTimeUs, true);
                if (!started) {
                    pending.add(copySample(true, buffer, info, pts));
                    if (pending.size() > 300) {
                        audioEnabled = false;
                        startIfReady();
                    }
                } else if (audioTrack >= 0) {
                    writeTrack(audioTrack, buffer, info, pts);
                }
            }
            return (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
        }
    }

    public void finish() {
        synchronized (lock) {
            if (!started) {
                audioEnabled = false;
                startIfReady();
            }
            if (!started || muxer == null) {
                return;
            }
            try {
                muxer.stop();
            } catch (Throwable ignored) {
            }
            started = false;
        }
    }

    public void release() {
        RecordCodecs.release(codec);
        synchronized (lock) {
            if (muxer == null) {
                return;
            }
            try {
                if (started) {
                    muxer.stop();
                }
            } catch (Throwable ignored) {
            }
            try {
                muxer.release();
            } catch (Throwable ignored) {
            }
            muxer = null;
            started = false;
        }
    }

    private boolean acceptVideo(int index, MediaCodec.BufferInfo info) {
        ByteBuffer buffer = codec.getOutputBuffer(index);
        boolean sample = info.size > 0
                && buffer != null
                && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
        if (sample) {
            wrote = true;
            long pts = rebaseVideo(info.presentationTimeUs);
            if (!started) {
                pending.add(copySample(false, buffer, info, pts));
                if (pending.size() > 300 && audioEnabled && audioFormat == null) {
                    audioEnabled = false;
                    startIfReady();
                }
            } else {
                writeTrack(videoTrack, buffer, info, pts);
            }
        }
        return (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
    }

    private void startIfReady() {
        if (started || videoFormat == null) {
            return;
        }
        if (audioEnabled && audioFormat == null) {
            return;
        }
        try {
            muxer = new MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            videoTrack = muxer.addTrack(videoFormat);
            if (audioFormat != null && audioEnabled) {
                audioTrack = muxer.addTrack(audioFormat);
            }
            muxer.start();
            started = true;
            for (int i = 0; i < pending.size(); i++) {
                PendingSample sample = pending.get(i);
                int track = sample.audio ? audioTrack : videoTrack;
                if (track < 0) {
                    continue;
                }
                writeTrack(track, ByteBuffer.wrap(sample.data), sample.info, sample.info.presentationTimeUs);
            }
            pending.clear();
        } catch (java.io.IOException error) {
            throw new IllegalStateException(error);
        }
    }

    private PendingSample copySample(
            boolean audio,
            ByteBuffer buffer,
            MediaCodec.BufferInfo info,
            long pts) {
        byte[] data = new byte[info.size];
        buffer.position(info.offset);
        buffer.limit(info.offset + info.size);
        buffer.get(data);
        MediaCodec.BufferInfo copy = new MediaCodec.BufferInfo();
        copy.set(0, data.length, pts, info.flags);
        return new PendingSample(audio, data, copy);
    }

    private void writeTrack(int track, ByteBuffer buffer, MediaCodec.BufferInfo info, long pts) {
        buffer.position(info.offset);
        buffer.limit(info.offset + info.size);
        long saved = info.presentationTimeUs;
        info.presentationTimeUs = pts;
        muxer.writeSampleData(track, buffer, info);
        info.presentationTimeUs = saved;
    }

    private long rebaseVideo(long pts) {
        if (videoOrigin < 0) {
            videoOrigin = pts;
        }
        long relative = pts - videoOrigin;
        if (relative < 0) {
            relative = 0;
        }
        return monotonic(relative, false);
    }

    private long monotonic(long pts, boolean audio) {
        long last = audio ? lastAudioPts : lastVideoPts;
        if (pts <= last) {
            pts = last + 1;
        }
        if (audio) {
            lastAudioPts = pts;
        } else {
            lastVideoPts = pts;
        }
        return pts;
    }

    private static final class PendingSample {
        final boolean audio;
        final byte[] data;
        final MediaCodec.BufferInfo info;

        PendingSample(boolean audio, byte[] data, MediaCodec.BufferInfo info) {
            this.audio = audio;
            this.data = data;
            this.info = info;
        }
    }
}
