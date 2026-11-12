package com.fire.adb.appservice;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Looper;
import android.util.Log;

import com.fire.adb.appservice.catalog.AppCatalogProtocol;
import com.fire.adb.appservice.clipboard.ClipboardProtocol;
import com.fire.adb.appservice.protocol.CommandHandler;
import com.fire.adb.appservice.protocol.FireDataReader;
import com.fire.adb.appservice.protocol.FireDataRequest;
import com.fire.adb.appservice.protocol.FireDataResponse;
import com.fire.adb.appservice.protocol.FireDataWriter;
import com.fire.adb.appservice.util.AndroidContexts;

import org.json.JSONObject;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/**
 * 桌面端经 {@code exec:} 拉起。命令线程读请求，读到 {@code session.quit} 或标准输入结束就退出。
 * 主线程停在 Looper 上，用来派发剪贴板变化。没有界面。
 *
 * <p>请求和响应都是 {@code name type id length:} 加正文。
 * 带 {@code link=} 时，进程仍由 {@code exec:} 托住，协议走本机反向端口。
 * 第一条是 {@code session.hello}，角色 {@code service}。
 * {@code catalog.*} 由 {@link AppCatalogProtocol} 实现，{@code clipboard.*} 由
 * {@link ClipboardProtocol} 实现。
 */
public final class FireAppService {
    private FireAppService() {}

    public static void main(String[] args) {
        FireDataWriter out = FireDataWriter.stdout();
        try {
            run(out, args);
        } catch (Throwable error) {
            error.printStackTrace();
            out.sendQuiet(FireDataResponse.error(0, String.valueOf(error.getMessage())));
            System.exit(1);
        }
    }

    private static boolean hasArg(String[] args, String name) {
        if (args == null) {
            return false;
        }
        for (String arg : args) {
            if (name.equals(arg)) {
                return true;
            }
        }
        return false;
    }

    private static void run(FireDataWriter stdout, String[] args) throws Exception {
        if (Looper.myLooper() == null) {
            Looper.prepareMainLooper();
        }
        Context context = AndroidContexts.system();
        PackageManager manager = context.getPackageManager();
        String link = argValue(args, "link");
        String token = argValue(args, "token");
        if (link != null && token != null) {
            watchStdin();
            final int port = Integer.parseInt(link);
            final String linkToken = token;
            Thread linkThread = new Thread(new Runnable() {
                @Override
                public void run() {
                    connectLoop(port, linkToken, context, manager);
                }
            }, "fire-app-link");
            linkThread.start();
            Looper.loop();
            return;
        }
        // 剪贴板必须用 shell 包名上下文：ClipboardService 会校验调用包名与
        // uid 匹配，system context 的包名 "android" 属于 uid 1000，会被直接拒绝。
        AppCatalogProtocol catalog = new AppCatalogProtocol(stdout, context, manager);
        ClipboardProtocol clipboard = new ClipboardProtocol(stdout, new ShellContext(context));
        clipboard.loadHistory();
        stdout.send(FireDataResponse.text("session.ready", 0, "1"));
        if (hasArg(args, "LIST")) {
            catalog.writeList(0);
            return;
        }
        CommandHandler[] handlers = new CommandHandler[] {catalog, clipboard};
        Thread commands = new Thread(
                () -> {
                    try {
                        readCommands(
                                new FireDataReader(new FileInputStream(FileDescriptor.in)),
                                stdout,
                                handlers);
                    } catch (Throwable error) {
                        Log.w("FireAdb", "命令循环退出", error);
                        stdout.sendQuiet(FireDataResponse.error(0, String.valueOf(error.getMessage())));
                    } finally {
                        try {
                            stdout.flush();
                        } catch (Throwable ignored) {
                        }
                        System.exit(0);
                    }
                },
                "fire-app-commands");
        commands.start();
        Looper.loop();
    }

    private static String argValue(String[] args, String key) {
        if (args == null) {
            return null;
        }
        String prefix = key + "=";
        for (String arg : args) {
            if (arg != null && arg.startsWith(prefix)) {
                return arg.substring(prefix.length());
            }
        }
        return null;
    }

    private static void watchStdin() {
        Thread watcher = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    FileInputStream in = new FileInputStream(FileDescriptor.in);
                    while (in.read() >= 0) {
                    }
                } catch (Exception ignored) {
                }
                System.exit(0);
            }
        }, "fire-app-stdin");
        watcher.setDaemon(true);
        watcher.start();
    }

    private static void connectLoop(
            int port,
            String token,
            Context context,
            PackageManager manager) {
        writeLinkFile(port, token);
        while (true) {
            Socket socket = new Socket();
            ClipboardProtocol clipboard = null;
            try {
                socket.connect(new InetSocketAddress("127.0.0.1", port), 3000);
                socket.setTcpNoDelay(true);
                FireDataWriter out = FireDataWriter.of(socket.getOutputStream());
                clipboard = new ClipboardProtocol(out, new ShellContext(context));
                clipboard.loadHistory();
                AppCatalogProtocol catalog = new AppCatalogProtocol(out, context, manager);
                JSONObject hello = new JSONObject();
                hello.put("role", "service");
                hello.put("token", token);
                out.send(FireDataResponse.json("session.hello", 0, hello));
                out.send(FireDataResponse.text("session.ready", 0, "1"));
                CommandHandler[] handlers = new CommandHandler[] {catalog, clipboard};
                readCommands(new FireDataReader(socket.getInputStream()), out, handlers);
            } catch (Exception error) {
                Log.w("FireAdb", "还没连上桌面", error);
            } finally {
                if (clipboard != null) {
                    clipboard.stopWatch();
                }
                try {
                    socket.close();
                } catch (Exception ignored) {
                }
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException interrupted) {
                return;
            }
        }
    }

    private static void writeLinkFile(int port, String token) {
        try {
            File dir = new File("/sdcard/Android/data/com.fire.adb/files");
            if (!dir.isDirectory() && !dir.mkdirs()) {
                Log.w("FireAdb", "链接目录没有创建");
            }
            File file = new File(dir, "fireadb-link");
            FileOutputStream raw = new FileOutputStream(file);
            try {
                raw.write((port + " " + token + "\n").getBytes(StandardCharsets.US_ASCII));
            } finally {
                raw.close();
            }
        } catch (Exception error) {
            Log.w("FireAdb", "链接说明没有写上", error);
        }
    }

    private static void readCommands(
            FireDataReader input,
            FireDataWriter out,
            CommandHandler[] handlers) throws Exception {
        FireDataRequest request;
        while ((request = input.read()) != null) {
            if ("session.quit".equals(request.name)) {
                System.exit(0);
            }
            if (!dispatch(handlers, request)) {
                out.send(FireDataResponse.error(request.id, "未知命令"));
            }
        }
    }

    private static boolean dispatch(CommandHandler[] handlers, FireDataRequest request)
            throws Exception {
        for (CommandHandler handler : handlers) {
            if (handler.handle(request)) {
                return true;
            }
        }
        return false;
    }
}
