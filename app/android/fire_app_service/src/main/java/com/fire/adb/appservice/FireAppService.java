package com.fire.adb.appservice;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Looper;
import android.os.Process;
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

import java.util.ArrayList;
import java.util.List;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.StandardCharsets;

/**
 * 桌面端拉起后留在后台。主线程停在 Looper 上，用来派发剪贴板变化。没有界面。
 * 不带 {@code link=} 的一次性命令读到 {@code session.quit} 或标准输入结束才退出。
 *
 * <p>请求和响应都是 {@code name type id length:} 加正文。
 * 带 {@code link=} 时，整台设备只留一个进程，并一直留在后台。
 * adb 连接断开、客户端全部离开，都不结束它。后来的启动拿不到锁就退出。
 * 进程向本机反向端口回连，并在 {@code 127.0.0.1:28171} 接受其他客户端。
 * 反向端口暂时没人接时，通知还连着的客户端把端口接过去。
 * 第一条是 {@code session.hello}，角色 {@code service}。
 * {@code catalog.*} 由 {@link AppCatalogProtocol} 实现，{@code clipboard.*} 由
 * {@link ClipboardProtocol} 实现。
 */
public final class FireAppService {
    /** 与桌面端 {@code deviceServicePort} 相同。本机其他客户端从这里接入。 */
    static final int LOCAL_PORT = 28171;
    private static final String LOCK_PATH = "/data/local/tmp/fire-app-service.lock";
    private static final String PID_PATH = "/data/local/tmp/fire-app-service.pid";
    private static final String OWNER_PATH = "/data/local/tmp/fire-app-service.owner";

    private static FileOutputStream lockStream;
    private static FileLock processLock;
    private static final Object SESSIONS = new Object();
    private static final List<FireDataWriter> localWriters = new ArrayList<FireDataWriter>();

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
            if (!acquireProcess()) {
                Log.i("FireAdb", "应用服务已在运行，本次退出");
                return;
            }
            final int port = Integer.parseInt(link);
            final String linkToken = token;
            Thread acceptThread = new Thread(new Runnable() {
                @Override
                public void run() {
                    acceptLoop(linkToken, context, manager);
                }
            }, "fire-app-accept");
            acceptThread.setDaemon(true);
            acceptThread.start();
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
                                handlers,
                                true);
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

    /**
     * 拿到独占锁才算这台设备上的那一个服务。锁被别人拿着就退出。
     * 文件系统不支持锁时仍继续，由启动方的目录占位避免起两个进程。
     */
    private static boolean acquireProcess() {
        try {
            lockStream = new FileOutputStream(LOCK_PATH);
            processLock = lockStream.getChannel().tryLock();
            if (processLock == null) {
                return false;
            }
        } catch (OverlappingFileLockException already) {
            return false;
        } catch (Exception error) {
            Log.w("FireAdb", "应用服务锁不可用，继续作为唯一进程", error);
        }
        try {
            FileOutputStream pid = new FileOutputStream(PID_PATH);
            try {
                pid.write(Integer.toString(Process.myPid()).getBytes(StandardCharsets.US_ASCII));
            } finally {
                pid.close();
            }
        } catch (Exception error) {
            Log.w("FireAdb", "没有写下进程号", error);
        }
        final int ownPid = Process.myPid();
        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
            @Override
            public void run() {
                deleteIfOwnPid(ownPid);
                new File(OWNER_PATH).delete();
            }
        }));
        return true;
    }

    private static void acceptLoop(
            String token,
            Context context,
            PackageManager manager) {
        ServerSocket server = null;
        try {
            server = new ServerSocket();
            server.setReuseAddress(true);
            server.bind(new InetSocketAddress("127.0.0.1", LOCAL_PORT), 8);
            while (true) {
                final Socket socket = server.accept();
                Thread client = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        serve(socket, token, context, manager, true);
                    }
                }, "fire-app-local");
                client.setDaemon(true);
                client.start();
            }
        } catch (Exception error) {
            Log.w("FireAdb", "本机接入端口没有听上", error);
        } finally {
            if (server != null) {
                try {
                    server.close();
                } catch (Exception ignored) {
                }
            }
        }
    }

    private static void connectLoop(
            int port,
            String token,
            Context context,
            PackageManager manager) {
        writeLinkFile(port, token);
        int failures = 0;
        while (true) {
            Socket socket = new Socket();
            boolean connected = false;
            try {
                socket.connect(new InetSocketAddress("127.0.0.1", port), 3000);
                connected = true;
                failures = 0;
                serve(socket, token, context, manager, false);
            } catch (Exception error) {
                failures++;
                if (failures == 1 || failures % 30 == 0) {
                    Log.i("FireAdb", "还没连上桌面");
                }
                try {
                    socket.close();
                } catch (Exception ignored) {
                }
                if (failures == 1 || failures % 5 == 0) {
                    notifyLocals();
                }
            }
            if (connected) {
                failures = 0;
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException interrupted) {
                return;
            }
        }
    }

    /**
     * 一条已经接上的客户端。这条连接结束只关掉自己，进程继续留在后台。
     */
    private static void serve(
            Socket socket,
            String token,
            Context context,
            PackageManager manager,
            boolean local) {
        ClipboardProtocol clipboard = null;
        FireDataWriter out = null;
        try {
            socket.setTcpNoDelay(true);
            out = FireDataWriter.of(socket.getOutputStream());
            if (local) {
                synchronized (SESSIONS) {
                    localWriters.add(out);
                }
            }
            clipboard = new ClipboardProtocol(out, new ShellContext(context));
            clipboard.loadHistory();
            AppCatalogProtocol catalog = new AppCatalogProtocol(out, context, manager);
            JSONObject hello = new JSONObject();
            hello.put("role", "service");
            hello.put("token", token);
            out.send(FireDataResponse.json("session.hello", 0, hello));
            out.send(FireDataResponse.text("session.ready", 0, "1"));
            CommandHandler[] handlers = new CommandHandler[] {catalog, clipboard};
            readCommands(
                    new FireDataReader(socket.getInputStream()),
                    out,
                    handlers,
                    false);
        } catch (Exception error) {
            Log.w("FireAdb", "服务连接结束", error);
        } finally {
            if (local && out != null) {
                synchronized (SESSIONS) {
                    localWriters.remove(out);
                }
            }
            if (clipboard != null) {
                clipboard.stopWatch();
            }
            try {
                socket.close();
            } catch (Exception ignored) {
            }
        }
    }

    /** 反向端口上暂时没有人。让还连着的客户端把端口接过去。 */
    private static void notifyLocals() {
        List<FireDataWriter> writers;
        synchronized (SESSIONS) {
            if (localWriters.isEmpty()) {
                return;
            }
            writers = new ArrayList<FireDataWriter>(localWriters);
        }
        for (FireDataWriter writer : writers) {
            try {
                writer.send(FireDataResponse.text("session.release", 0, ""));
            } catch (Exception ignored) {
            }
        }
    }

    /** 只删自己写下的进程号，避免关掉旧进程时清掉新进程的标记。 */
    private static void deleteIfOwnPid(int ownPid) {
        File file = new File(PID_PATH);
        try {
            FileInputStream input = new FileInputStream(file);
            byte[] raw = new byte[32];
            int count;
            try {
                count = input.read(raw);
            } finally {
                input.close();
            }
            if (count <= 0) {
                return;
            }
            String text = new String(raw, 0, count, StandardCharsets.US_ASCII).trim();
            if (text.equals(Integer.toString(ownPid))) {
                file.delete();
            }
        } catch (Exception ignored) {
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
            CommandHandler[] handlers,
            boolean exitOnQuit) throws Exception {
        FireDataRequest request;
        while ((request = input.read()) != null) {
            if ("session.quit".equals(request.name)) {
                if (exitOnQuit) {
                    System.exit(0);
                }
                return;
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
