package com.fire.adb.appservice.protocol;

/** 一条请求的实现。认领了就返回 true。 */
public interface CommandHandler {
    boolean handle(FireDataRequest request) throws Exception;
}
