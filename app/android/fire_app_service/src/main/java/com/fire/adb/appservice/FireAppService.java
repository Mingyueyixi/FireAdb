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

import java.io.FileDescriptor;
import java.io.FileInputStream;

/**
 * 桌面端经 {@code exec:} 拉起。命令线程读标准输入，读到 {@code session.quit} 或结束就退出进程。
 * 主线程停在 Looper 上，用来派发剪贴板变化。没有界面。
 *
 * <p>请求和响应都是 {@code name type id length:} 加正文。
 * {@code catalog.*} 由 {@link AppCatalogProtocol} 实现，{@code clipboard.*} 由
 * {@link ClipboardProtocol} 实现。聊天不经过这里：手机监听本机端口，桌面用 adb 直连。
 * 新功能实现 {@link CommandHandler}，再放进命令数组。
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

    private static void run(FireDataWriter out, String[] args) throws Exception {
        if (Looper.myLooper() == null) {
            Looper.prepareMainLooper();
        }
        Context context = AndroidContexts.system();
        PackageManager manager = context.getPackageManager();
        AppCatalogProtocol catalog = new AppCatalogProtocol(out, context, manager);
        // 剪贴板必须用 shell 包名上下文：ClipboardService 会校验调用包名与
        // uid 匹配，system context 的包名 "android" 属于 uid 1000，会被直接
        // 拒绝（"Package android does not belong to 2000"）。伪装成
        // com.android.shell 后与 shell uid (2000) 匹配，命中系统的测试豁免。
        ClipboardProtocol clipboard = new ClipboardProtocol(out, new ShellContext(context));
        clipboard.loadHistory();
        out.send(FireDataResponse.text("session.ready", 0, "1"));

        // 参数里的 LIST 仍一次性写出目录后退出，供调试。正常界面走 stdin。
        if (hasArg(args, "LIST")) {
            catalog.writeList(0);
            return;
        }

        // stdin 命令挪到工作线程，主线程进 Looper：ClipboardManager 的变化
        // 回调（注册时落在主线程 Handler 上）只有主线程在 loop() 里才派发。
        // 命令应答与回调推送都写 stdout，整条响应由 FireDataWriter 的锁包住。
        // 注意：prepareMainLooper 建的队列 mQuitAllowed=false，quitSafely()
        // 会抛 "Main thread not allowed to quit."——主 Looper 退不掉，命令
        // 线程结束时直接 System.exit 终止进程。
        CommandHandler[] handlers = new CommandHandler[] {
                catalog, clipboard
        };
        Thread commands = new Thread(
                () -> {
                    try {
                        readCommands(out, handlers);
                    } catch (Throwable error) {
                        Log.w("FireAdb", "命令循环退出", error);
                        out.sendQuiet(FireDataResponse.error(0, String.valueOf(error.getMessage())));
                    } finally {
                        try {
                            out.flush();
                        } catch (Throwable ignored) {
                        }
                        System.exit(0);
                    }
                },
                "fire-app-commands");
        commands.start();
        Looper.loop();
    }

    private static void readCommands(FireDataWriter out, CommandHandler[] handlers) throws Exception {
        FireDataReader input = new FireDataReader(new FileInputStream(FileDescriptor.in));
        FireDataRequest request;
        while ((request = input.read()) != null) {
            if ("session.quit".equals(request.name)) {
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
