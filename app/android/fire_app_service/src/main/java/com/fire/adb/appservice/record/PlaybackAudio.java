package com.fire.adb.appservice.record;

import android.annotation.SuppressLint;
import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Process;

import com.fire.adb.appservice.ShellContext;
import com.fire.adb.appservice.util.LogUtils;

import java.nio.ByteBuffer;

/**
 * 采集正在播放的声音并编码成 AAC。
 * 环回成功时扬声器自己出声。环回失败时采集远程混音，再把同一份声音送回扬声器。
 */
public final class PlaybackAudio implements Runnable {
    static final int SAMPLE_RATE = 48000;

    private final Context context;
    private final Mp4Writer writer;
    private final Thread thread = new Thread(this, "fireadb-audio");
    private final LoopbackCapture loopback;
    private AudioRecord record;
    private AudioTrack speaker;
    private MediaCodec codec;
    private int channels = 2;
    private int bytesPerFrame = 4;
    private long samples;
    private volatile boolean stop;
    private boolean ended;

    private PlaybackAudio(Context context, Mp4Writer writer) {
        this.context = context;
        this.writer = writer;
        this.loopback = new LoopbackCapture(context);
    }

    public static PlaybackAudio tryStart(Context context, Mp4Writer writer) {
        PlaybackAudio audio = new PlaybackAudio(context, writer);
        try {
            audio.open();
            writer.enableAudio();
            audio.thread.start();
            return audio;
        } catch (Throwable error) {
            LogUtils.e("audio skipped", error);
            audio.release();
            writer.abandonAudio();
            return null;
        }
    }

    public void end() {
        if (ended) {
            return;
        }
        stop = true;
        AudioRecord current = record;
        if (current != null) {
            try {
                current.stop();
            } catch (Throwable ignored) {
            }
        }
        try {
            if (thread.isAlive()) {
                thread.join(20000);
            }
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
        ended = !thread.isAlive();
    }

    public void release() {
        if (!ended) {
            end();
        }
        if (!thread.isAlive()) {
            releaseQuiet();
        }
    }

    @SuppressLint("PrivateApi")
    private void open() throws Exception {
        boolean loopbackReady = true;
        try {
            record = loopback.open();
            channels = 2;
            bytesPerFrame = 4;
        } catch (Throwable error) {
            LogUtils.e("loopback", error);
            loopback.unregister();
            record = openPlaybackRecord();
            speaker = openSpeaker();
            loopbackReady = false;
        }
        record.startRecording();
        if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
            throw new IllegalStateException("audio recorder did not start");
        }
        MediaFormat format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                SAMPLE_RATE,
                channels);
        format.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC);
        format.setInteger(MediaFormat.KEY_BIT_RATE, 128000);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384);
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        codec.start();
        LogUtils.i(loopbackReady ? "audio loopback" : "audio submix");
    }

    @SuppressLint({"MissingPermission", "WrongConstant"})
    private AudioRecord openPlaybackRecord() {
        int[] masks = new int[] {
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.CHANNEL_IN_MONO,
        };
        int[] counts = new int[] {2, 1};
        for (int i = 0; i < masks.length; i++) {
            int buffer = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE,
                    masks[i],
                    AudioFormat.ENCODING_PCM_16BIT);
            if (buffer <= 0) {
                buffer = SAMPLE_RATE;
            }
            int size = Math.max(buffer * 4, counts[i] * 2 * 1024);
            AudioRecord created = new AudioRecord.Builder()
                    .setContext(new ShellContext(context))
                    .setAudioSource(8)
                    .setAudioFormat(new AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelMask(masks[i])
                            .build())
                    .setBufferSizeInBytes(size)
                    .build();
            if (created.getState() == AudioRecord.STATE_INITIALIZED) {
                channels = counts[i];
                bytesPerFrame = counts[i] * 2;
                return created;
            }
            created.release();
        }
        throw new IllegalStateException("playback recorder unavailable");
    }

    private AudioTrack openSpeaker() {
        int mask = channels == 2
                ? AudioFormat.CHANNEL_OUT_STEREO
                : AudioFormat.CHANNEL_OUT_MONO;
        int buffer = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                mask,
                AudioFormat.ENCODING_PCM_16BIT);
        if (buffer < bytesPerFrame) {
            buffer = bytesPerFrame * 4096;
        }
        AudioTrack track = new AudioTrack(
                new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(mask)
                        .build(),
                buffer * 2,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE);
        if (track.getState() != AudioTrack.STATE_INITIALIZED) {
            track.release();
            LogUtils.w("speaker unavailable");
            return null;
        }
        AudioDeviceInfo device = builtinSpeaker();
        if (device != null) {
            track.setPreferredDevice(device);
        }
        track.play();
        return track;
    }

    private AudioDeviceInfo builtinSpeaker() {
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (manager == null) {
            return null;
        }
        AudioDeviceInfo[] devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        for (int i = 0; i < devices.length; i++) {
            if (devices[i].getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                return devices[i];
            }
        }
        return null;
    }

    @Override
    public void run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO);
        try {
            pump();
        } catch (Throwable error) {
            LogUtils.e("audio", error);
            writer.abandonAudio();
        }
    }

    private void pump() {
        byte[] pcm = new byte[bytesPerFrame * 1024];
        int pending = 0;
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (!stop) {
            int read = record.read(pcm, pending, pcm.length - pending);
            if (read < 0) {
                break;
            }
            int total = pending + read;
            int usable = total - (total % bytesPerFrame);
            if (usable > 0) {
                play(pcm, usable);
                queuePcm(pcm, usable);
                drain(info, false);
            }
            int rest = total - usable;
            if (rest > 0 && usable > 0) {
                System.arraycopy(pcm, usable, pcm, 0, rest);
            }
            pending = rest;
        }
        signalEos();
        drain(info, true);
    }

    private void play(byte[] pcm, int size) {
        AudioTrack track = speaker;
        if (track == null || size <= 0) {
            return;
        }
        try {
            track.write(pcm, 0, size, AudioTrack.WRITE_NON_BLOCKING);
        } catch (Throwable ignored) {
        }
    }

    private void queuePcm(byte[] pcm, int size) {
        int index = codec.dequeueInputBuffer(10000);
        if (index < 0) {
            return;
        }
        ByteBuffer input = codec.getInputBuffer(index);
        if (input == null) {
            return;
        }
        input.clear();
        int accepted = Math.min(size, input.remaining());
        accepted -= accepted % bytesPerFrame;
        if (accepted <= 0) {
            return;
        }
        input.put(pcm, 0, accepted);
        long pts = samples * 1000000L / SAMPLE_RATE;
        samples += accepted / bytesPerFrame;
        codec.queueInputBuffer(index, 0, accepted, pts, 0);
    }

    private void signalEos() {
        int index = codec.dequeueInputBuffer(10000);
        if (index < 0) {
            return;
        }
        codec.queueInputBuffer(
                index,
                0,
                0,
                samples * 1000000L / SAMPLE_RATE,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM);
    }

    private void drain(MediaCodec.BufferInfo info, boolean untilEos) {
        while (true) {
            int index = codec.dequeueOutputBuffer(info, untilEos ? 10000 : 0);
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return;
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                writer.addAudioFormat(codec.getOutputFormat());
                continue;
            }
            if (index < 0) {
                continue;
            }
            ByteBuffer buffer = codec.getOutputBuffer(index);
            boolean eos = writer.acceptAudio(buffer, info);
            codec.releaseOutputBuffer(index, false);
            if (eos || (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                return;
            }
        }
    }

    private void releaseQuiet() {
        if (codec != null) {
            RecordCodecs.release(codec);
            codec = null;
        }
        if (record != null) {
            try {
                record.release();
            } catch (Throwable ignored) {
            }
            record = null;
        }
        if (speaker != null) {
            try {
                speaker.release();
            } catch (Throwable ignored) {
            }
            speaker = null;
        }
        loopback.unregister();
    }
}
