package com.fire.adb.appservice.record;

import java.io.File;

/** 限时或停止文件一到，录屏就收尾。 */
public final class RecordStop {
    public static final String STOP_PATH = "/data/local/tmp/fireadb_rec.stop";

    private final long limitNs;
    private final long start = System.nanoTime();

    public RecordStop(int timeLimitSec) {
        limitNs = timeLimitSec <= 0 ? 0L : timeLimitSec * 1000000000L;
    }

    public boolean requested() {
        if (new File(STOP_PATH).exists()) {
            return true;
        }
        return limitNs > 0L && System.nanoTime() - start >= limitNs;
    }
}
