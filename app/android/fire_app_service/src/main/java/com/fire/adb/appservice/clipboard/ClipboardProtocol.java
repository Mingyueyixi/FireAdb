package com.fire.adb.appservice.clipboard;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.util.Log;

import com.fire.adb.appservice.protocol.CommandHandler;
import com.fire.adb.appservice.protocol.FireDataRequest;
import com.fire.adb.appservice.protocol.FireDataResponse;
import com.fire.adb.appservice.protocol.FireDataWriter;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;

/**
 * 剪贴板：{@code clipboard.get}、{@code clipboard.set}、{@code clipboard.history}、
 * {@code clipboard.watch}。变化经 {@code clipboard.event} 推送，请求号为 0。
 *
 * <p>调用方传入的上下文必须是 shell 包名（{@code com.android.shell}），
 * 否则剪贴板服务会拒绝。Android 只有当前一条剪贴板，历史由这里记录并落盘，新的在前。
 * 变化回调在主 Looper 上，和命令线程一起写标准输出。
 */
public final class ClipboardProtocol implements CommandHandler {
    private static final String TAG = "FireAdb";
    private static final int HISTORY_MAX = 20;
    private static final String HISTORY_PATH = "/data/local/tmp/fire-adb-clip-history.json";
    /** 本进程写入的剪贴板标记。监听时见到它就不再回推。 */
    private static final String CLIP_LABEL = "FireAdb";

    private final FireDataWriter out;
    private final Context context;
    private final ArrayDeque<String> history = new ArrayDeque<String>();
    private final ClipboardManager.OnPrimaryClipChangedListener clipListener =
            this::onClipChanged;

    private ClipboardManager clipboardManager;
    /** 命令线程写、主线程读。注册监听之前置位。 */
    private volatile boolean watching;

    public ClipboardProtocol(FireDataWriter out, Context context) {
        this.out = out;
        this.context = context;
    }

    @Override
    public boolean handle(FireDataRequest request) throws Exception {
        if ("clipboard.get".equals(request.name)) {
            handleGet(request.id);
            return true;
        }
        if ("clipboard.history".equals(request.name)) {
            handleHistory(request.id);
            return true;
        }
        if ("clipboard.set".equals(request.name)) {
            handleSet(request);
            return true;
        }
        if ("clipboard.watch".equals(request.name)) {
            handleWatch(request);
            return true;
        }
        return false;
    }

    /** 坏文件直接丢弃，不阻塞剪贴板功能。进程起来后、写出就绪帧之前调用。 */
    public void loadHistory() {
        try {
            File file = new File(HISTORY_PATH);
            if (!file.isFile()) {
                return;
            }
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            FileInputStream in = new FileInputStream(file);
            try {
                byte[] chunk = new byte[8192];
                int got;
                while ((got = in.read(chunk)) > 0) {
                    buffer.write(chunk, 0, got);
                }
            } finally {
                in.close();
            }
            byte[] data = buffer.toByteArray();
            int offset = 0;
            synchronized (history) {
                history.clear();
                while (offset + 4 <= data.length && history.size() < HISTORY_MAX) {
                    int length = ((data[offset] & 0xFF) << 24)
                            | ((data[offset + 1] & 0xFF) << 16)
                            | ((data[offset + 2] & 0xFF) << 8)
                            | (data[offset + 3] & 0xFF);
                    offset += 4;
                    if (length < 0 || offset + length > data.length) {
                        break;
                    }
                    String text = new String(data, offset, length, StandardCharsets.UTF_8);
                    offset += length;
                    if (text.length() > 0) {
                        history.addLast(text);
                    }
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "读取剪贴板历史失败", error);
        }
    }

    private void handleGet(int id) {
        try {
            out.send(FireDataResponse.json("clipboard.data", id, textJson(clipText())));
        } catch (Throwable error) {
            out.sendQuiet(FireDataResponse.error(id, String.valueOf(error.getMessage())));
        }
    }

    private void handleHistory(int id) {
        try {
            // WATCH 关着时，只有这里能把当前剪贴板纳入历史。
            remember(clipText());
            String[] items;
            synchronized (history) {
                items = history.toArray(new String[0]);
            }
            JSONArray list = new JSONArray();
            for (String item : items) {
                list.put(item);
            }
            JSONObject json = new JSONObject();
            json.put("items", list);
            out.send(FireDataResponse.json("clipboard.history", id, json));
        } catch (Throwable error) {
            out.sendQuiet(FireDataResponse.error(id, String.valueOf(error.getMessage())));
        }
    }

    private void handleSet(FireDataRequest request) {
        try {
            String text = request.json().optString("text", "");
            clipboard().setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, text));
            remember(text);
            out.send(FireDataResponse.none("clipboard.ok", request.id));
        } catch (Throwable error) {
            Log.w(TAG, "clipboard.set 失败", error);
            out.sendQuiet(FireDataResponse.error(request.id, "写入剪贴板失败: " + error.getMessage()));
        }
    }

    private void handleWatch(FireDataRequest request) {
        boolean on = false;
        try {
            on = request.json().optBoolean("on");
            ClipboardManager clips = clipboard();
            if (on && !watching) {
                watching = true;
                clips.addPrimaryClipChangedListener(clipListener);
            } else if (!on && watching) {
                watching = false;
                clips.removePrimaryClipChangedListener(clipListener);
            }
            out.send(FireDataResponse.none("clipboard.ok", request.id));
        } catch (Throwable error) {
            watching = false;
            out.sendQuiet(FireDataResponse.error(request.id, "监听剪贴板失败: " + error.getMessage()));
        }
    }

    /** 剪贴板变化回调（主 Looper）。label 是本进程写入的标记时不回推。 */
    private void onClipChanged() {
        try {
            if (!watching || writtenByUs()) {
                return;
            }
            String text = clipText();
            if (text.length() == 0) {
                return;
            }
            remember(text);
            out.send(FireDataResponse.json("clipboard.event", 0, textJson(text)));
        } catch (Throwable ignored) {
        }
    }

    private boolean writtenByUs() {
        try {
            ClipData clip = clipboard().getPrimaryClip();
            if (clip == null) {
                return false;
            }
            CharSequence label = clip.getDescription().getLabel();
            return label != null && CLIP_LABEL.contentEquals(label);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static String textJson(String text) throws Exception {
        JSONObject json = new JSONObject();
        json.put("text", text == null ? "" : text);
        return json.toString();
    }

    /**
     * 依赖 shell 上下文重载的 {@code getSystemService}。
     * 不能改用 base 里缓存的管理器，那个记住的包名是 android，会被服务拒绝。
     */
    private ClipboardManager clipboard() {
        if (clipboardManager == null) {
            clipboardManager = (ClipboardManager)
                    context.getSystemService(Context.CLIPBOARD_SERVICE);
        }
        return clipboardManager;
    }

    /**
     * 取出剪贴板上的文本。{@link ClipData.Item#coerceToText} 得到的是原文，
     * emoji 以 UTF-16 代理对留在字符串里，随消息正文按 UTF-8 传出。
     */
    private String clipText() {
        try {
            ClipboardManager clips = clipboard();
            if (!clips.hasPrimaryClip()) {
                return "";
            }
            ClipData clip = clips.getPrimaryClip();
            if (clip == null) {
                return "";
            }
            for (int i = 0; i < clip.getItemCount(); i++) {
                CharSequence value = clip.getItemAt(i).coerceToText(context);
                if (value == null) {
                    continue;
                }
                String text = value.toString();
                if (text.length() > 0) {
                    return text;
                }
            }
            return "";
        } catch (Throwable ignored) {
            return "";
        }
    }

    /** 去重置顶，超限截尾。落盘格式：每条 int32 UTF-8 长度 + 字节，新的在前。 */
    private void remember(String text) {
        if (text == null || text.length() == 0) {
            return;
        }
        synchronized (history) {
            history.remove(text);
            history.addFirst(text);
            while (history.size() > HISTORY_MAX) {
                history.removeLast();
            }
        }
        saveHistory();
    }

    private void saveHistory() {
        try {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            synchronized (history) {
                for (String text : history) {
                    byte[] utf = text.getBytes(StandardCharsets.UTF_8);
                    buffer.write((utf.length >>> 24) & 0xFF);
                    buffer.write((utf.length >>> 16) & 0xFF);
                    buffer.write((utf.length >>> 8) & 0xFF);
                    buffer.write(utf.length & 0xFF);
                    buffer.write(utf);
                }
            }
            FileOutputStream file = new FileOutputStream(HISTORY_PATH);
            try {
                buffer.writeTo(file);
            } finally {
                file.close();
            }
        } catch (Throwable ignored) {
        }
    }
}
