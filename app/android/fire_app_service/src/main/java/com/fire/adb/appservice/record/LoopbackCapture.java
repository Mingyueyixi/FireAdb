package com.fire.adb.appservice.record;

import android.annotation.SuppressLint;
import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;

import com.fire.adb.appservice.ShellContext;
import com.fire.adb.appservice.util.LogUtils;

import java.lang.reflect.Method;

/**
 * 把正在播放的声音环回成一条可录的音轨，设备自己的播放不停。
 * 系统给出的录音器没初始化时，再按混音地址打开远程混音。
 */
final class LoopbackCapture {
    private final Context context;
    private Object policy;
    private int bytesPerFrame = 4;

    LoopbackCapture(Context context) {
        this.context = context;
    }

    @SuppressLint("PrivateApi")
    AudioRecord open() throws Exception {
        bytesPerFrame = 4;
        Class<?> ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule");
        Class<?> ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule$Builder");
        Object ruleBuilder = ruleBuilderClass.getConstructor().newInstance();
        try {
            int role = ruleClass.getField("MIX_ROLE_PLAYERS").getInt(null);
            ruleBuilderClass.getMethod("setTargetMixRole", int.class)
                    .invoke(ruleBuilder, Integer.valueOf(role));
        } catch (Throwable ignored) {
        }
        int matchUsage = ruleClass.getField("RULE_MATCH_ATTRIBUTE_USAGE").getInt(null);
        Method addMixRule = null;
        try {
            addMixRule = ruleBuilderClass.getMethod("addMixRule", int.class, Object.class);
        } catch (NoSuchMethodException ignored) {
        }
        Method addRule = addMixRule == null
                ? ruleBuilderClass.getMethod("addRule", AudioAttributes.class, int.class)
                : null;
        int[] usages = new int[] {
                AudioAttributes.USAGE_MEDIA,
                AudioAttributes.USAGE_GAME,
                AudioAttributes.USAGE_UNKNOWN,
                AudioAttributes.USAGE_ALARM,
                AudioAttributes.USAGE_NOTIFICATION,
                AudioAttributes.USAGE_NOTIFICATION_RINGTONE,
                AudioAttributes.USAGE_ASSISTANCE_SONIFICATION,
                AudioAttributes.USAGE_VOICE_COMMUNICATION,
        };
        for (int i = 0; i < usages.length; i++) {
            AudioAttributes attributes = new AudioAttributes.Builder().setUsage(usages[i]).build();
            try {
                if (addMixRule != null) {
                    addMixRule.invoke(ruleBuilder, Integer.valueOf(matchUsage), attributes);
                } else {
                    addRule.invoke(ruleBuilder, attributes, Integer.valueOf(matchUsage));
                }
            } catch (Throwable ignored) {
            }
        }
        try {
            ruleBuilderClass.getMethod("voiceCommunicationCaptureAllowed", boolean.class)
                    .invoke(ruleBuilder, Boolean.TRUE);
        } catch (Throwable ignored) {
        }
        Object rule = ruleBuilderClass.getMethod("build").invoke(ruleBuilder);

        Class<?> mixClass = Class.forName("android.media.audiopolicy.AudioMix");
        Class<?> mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix$Builder");
        Object mixBuilder = mixBuilderClass.getConstructor(ruleClass).newInstance(rule);
        AudioFormat format = new AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(PlaybackAudio.SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build();
        mixBuilderClass.getMethod("setFormat", AudioFormat.class).invoke(mixBuilder, format);
        int loopBack = mixClass.getField("ROUTE_FLAG_LOOP_BACK").getInt(null);
        int render = mixClass.getField("ROUTE_FLAG_RENDER").getInt(null);
        int route = loopBack | render;
        try {
            route = mixClass.getField("ROUTE_FLAG_LOOP_BACK_RENDER").getInt(null);
        } catch (Throwable ignored) {
        }
        mixBuilderClass.getMethod("setRouteFlags", int.class)
                .invoke(mixBuilder, Integer.valueOf(route));
        Object mix = mixBuilderClass.getMethod("build").invoke(mixBuilder);

        Class<?> policyClass = Class.forName("android.media.audiopolicy.AudioPolicy");
        Class<?> policyBuilderClass = Class.forName("android.media.audiopolicy.AudioPolicy$Builder");
        Object policyBuilder = policyBuilderClass.getConstructor(Context.class)
                .newInstance(new ShellContext(context));
        policyBuilderClass.getMethod("addMix", mixClass).invoke(policyBuilder, mix);
        Object built = policyBuilderClass.getMethod("build").invoke(policyBuilder);
        Method register = AudioManager.class.getDeclaredMethod(
                "registerAudioPolicyStatic",
                policyClass);
        register.setAccessible(true);
        Object result = register.invoke(null, built);
        int code = result instanceof Integer ? ((Integer) result).intValue() : -1;
        if (code != 0) {
            throw new IllegalStateException("registerAudioPolicy " + result);
        }
        policy = built;
        return openSink(built, policyClass, mix, mixClass);
    }

    void unregister() {
        Object current = policy;
        policy = null;
        if (current == null) {
            return;
        }
        try {
            Class<?> policyClass = current.getClass();
            Method method;
            try {
                method = AudioManager.class.getDeclaredMethod(
                        "unregisterAudioPolicyStatic",
                        policyClass);
            } catch (NoSuchMethodException missing) {
                method = AudioManager.class.getDeclaredMethod(
                        "unregisterAudioPolicyAsyncStatic",
                        policyClass);
            }
            method.setAccessible(true);
            method.invoke(null, current);
        } catch (Throwable error) {
            LogUtils.w("audio policy: " + error);
        }
    }

    private AudioRecord openSink(
            Object built,
            Class<?> policyClass,
            Object mix,
            Class<?> mixClass) throws Exception {
        AudioRecord created = (AudioRecord) policyClass
                .getMethod("createAudioRecordSink", mixClass)
                .invoke(built, mix);
        if (created != null && created.getState() == AudioRecord.STATE_INITIALIZED) {
            return created;
        }
        int state = created == null ? -1 : created.getState();
        if (created != null) {
            try {
                created.release();
            } catch (Throwable ignored) {
            }
        }
        String address = mixAddress(mix, mixClass);
        LogUtils.i("loopback sink state=" + state + " addr=" + address);
        if (address.length() == 0) {
            throw new IllegalStateException(
                    "loopback recorder unavailable state=" + state);
        }
        return openTaggedSubmix(address);
    }

    private static String mixAddress(Object mix, Class<?> mixClass) {
        try {
            Object value = mixClass.getMethod("getRegistration").invoke(mix);
            return value == null ? "" : String.valueOf(value);
        } catch (Throwable ignored) {
            return "";
        }
    }

    private AudioRecord openTaggedSubmix(String address) throws Exception {
        AudioAttributes.Builder attributes = new AudioAttributes.Builder();
        AudioAttributes.Builder.class
                .getMethod("setInternalCapturePreset", int.class)
                .invoke(attributes, Integer.valueOf(8));
        Method addTag = AudioAttributes.Builder.class.getMethod("addTag", String.class);
        addTag.invoke(attributes, "addr=" + address);
        addTag.invoke(attributes, "fixedVolume");
        AudioFormat format = new AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(PlaybackAudio.SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build();
        int buffer = AudioRecord.getMinBufferSize(
                PlaybackAudio.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT);
        if (buffer < bytesPerFrame) {
            buffer = bytesPerFrame * 4096;
        }
        Object builder = AudioRecord.Builder.class.getConstructor().newInstance();
        Class<?> builderClass = builder.getClass();
        builderClass.getMethod("setContext", Context.class)
                .invoke(builder, new ShellContext(context));
        builderClass.getMethod("setAudioAttributes", AudioAttributes.class)
                .invoke(builder, attributes.build());
        builderClass.getMethod("setAudioFormat", AudioFormat.class)
                .invoke(builder, format);
        builderClass.getMethod("setBufferSizeInBytes", int.class)
                .invoke(builder, Integer.valueOf(Math.max(buffer * 4, bytesPerFrame * 1024)));
        AudioRecord record = (AudioRecord) builderClass.getMethod("build").invoke(builder);
        if (record.getState() != AudioRecord.STATE_INITIALIZED) {
            record.release();
            throw new IllegalStateException("loopback recorder unavailable");
        }
        return record;
    }
}
