package com.fire.adb.appservice.protocol;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** 请求和响应共用的头、正文编解码。调用方只接触 {@link FireDataRequest} 和 {@link FireDataResponse}。 */
final class FireDataCodec {
    private static final int MAX_HEADER = 8 * 1024;
    /** 正文按到达的数据分段读，不按声明的长度一次分配。 */
    private static final int BODY_CHUNK = 64 * 1024;

    private FireDataCodec() {}

    static byte[] header(String name, String type, int id, int length) throws IOException {
        if (length < 0) {
            throw new IOException("长度无效");
        }
        byte[] raw = (name + " " + type + " " + id + " " + length + ":")
                .getBytes(StandardCharsets.US_ASCII);
        if (raw.length > MAX_HEADER) {
            throw new IOException("消息头过大");
        }
        return raw;
    }

    static String display(String name, String type, int id, byte[] body) {
        byte[] payload = body == null ? new byte[0] : body;
        String head = name + " " + type + " " + id + " " + payload.length + ":";
        if ("bytes".equals(type)) {
            return head + "<" + payload.length + " 字节>";
        }
        if (payload.length == 0) {
            return head;
        }
        return head + new String(payload, StandardCharsets.UTF_8);
    }

    /** 流一开始就结束时返回 null。读到一半结束则抛出。 */
    static Decoded read(InputStream in) throws IOException {
        String name = readUntil(in, (byte) ' ', true);
        if (name == null) {
            return null;
        }
        String type = readUntil(in, (byte) ' ', false);
        String idText = readUntil(in, (byte) ' ', false);
        String lengthText = readUntil(in, (byte) ':', false);
        int headerBytes = name.length() + type.length() + idText.length()
                + lengthText.length() + 4;
        if (headerBytes > MAX_HEADER) {
            throw new IOException("消息头过大");
        }
        int id = parseInt(idText, "请求号");
        int length = parseInt(lengthText, "长度");
        if (length < 0) {
            throw new IOException("长度无效");
        }
        return new Decoded(name, type, id, readBody(in, length));
    }

    /** 读满 {@code length} 个实际到达的字节。长度只标出这条消息的边界。 */
    private static byte[] readBody(InputStream in, int length) throws IOException {
        if (length == 0) {
            return new byte[0];
        }
        ByteArrayOutputStream buffer = new ByteArrayOutputStream(
                length < BODY_CHUNK ? length : BODY_CHUNK);
        byte[] chunk = new byte[BODY_CHUNK];
        int remaining = length;
        while (remaining > 0) {
            int want = remaining < chunk.length ? remaining : chunk.length;
            int got = in.read(chunk, 0, want);
            if (got < 0) {
                throw new EOFException("消息未完成");
            }
            buffer.write(chunk, 0, got);
            remaining -= got;
        }
        return buffer.toByteArray();
    }

    private static String readUntil(InputStream in, byte delimiter, boolean eofAtStart)
            throws IOException {
        byte[] raw = new byte[64];
        int size = 0;
        while (true) {
            int value = in.read();
            if (value < 0) {
                if (eofAtStart && size == 0) {
                    return null;
                }
                throw new EOFException("消息未完成");
            }
            if (value == delimiter) {
                break;
            }
            if (size >= MAX_HEADER) {
                throw new IOException("消息头过大");
            }
            if (size == raw.length) {
                byte[] grown = new byte[raw.length * 2];
                System.arraycopy(raw, 0, grown, 0, size);
                raw = grown;
            }
            raw[size++] = (byte) value;
        }
        return new String(raw, 0, size, StandardCharsets.US_ASCII);
    }

    private static int parseInt(String text, String label) throws IOException {
        try {
            return Integer.parseInt(text);
        } catch (NumberFormatException error) {
            throw new IOException(label + "无效");
        }
    }

    static final class Decoded {
        final String name;
        final String type;
        final int id;
        final byte[] body;

        Decoded(String name, String type, int id, byte[] body) {
            this.name = name;
            this.type = type;
            this.id = id;
            this.body = body;
        }
    }
}
