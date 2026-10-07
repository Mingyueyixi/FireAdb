// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'fire_adb_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class FireAdbLocalizationsZh extends FireAdbLocalizations {
  FireAdbLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsChinese => '中文';

  @override
  String get settingsEnglish => '英文';

  @override
  String settingsLanguageSaveFailed(Object error) {
    return '保存语言设置失败：$error';
  }

  @override
  String get homeConnectionSucceeded => '连接成功';

  @override
  String homeConnectedDevice(Object serial) {
    return '已连接：$serial';
  }

  @override
  String get homeConnectionFailed => '连接失败';

  @override
  String get homeInvalidInput => '输入无效';

  @override
  String get homeInvalidHostPort => '请输入有效的主机地址与端口（1-65535）';

  @override
  String get homeDeviceUnavailable => '设备不可用';

  @override
  String get homeAdbDeviceMissing => '该设备当前未出现在 ADB 设备列表中，请先连接设备并刷新列表。';

  @override
  String get homeDeviceDisconnected => '设备已断开';

  @override
  String get homeDisconnectSucceeded => '已断开连接';

  @override
  String get homeDisconnectFailed => '断开失败';

  @override
  String get homeManualConnection => '手动连接';

  @override
  String get homeHostAddress => '主机地址';

  @override
  String get homeHostAddressExample => '例如 192.168.1.100';

  @override
  String get homePort => '端口';

  @override
  String get homeConnecting => '连接中…';

  @override
  String get commonConnect => '连接';

  @override
  String get homeDeviceDiscovery => '设备发现（mDNS）';

  @override
  String get homeScanning => '扫描中…';

  @override
  String get homeScan => '扫描';

  @override
  String get homeWifiDebugInfo => '仅适用于开启「无线调试」的 Android 11+ 设备';

  @override
  String get homeMdnsHelp =>
      '✅ 能发现：\n• 设置 → 开发者选项 → 无线调试 → 已开启\n• 手机与电脑在同一 Wi-Fi（无 AP 隔离）\n\n❌ 无法发现：\n• 仅开启 USB 调试、未开无线调试\n• 通过 `adb connect IP:PORT` 手动连接的设备\n• Android 11 以下或未实现 mDNS 广播的 ROM\n\n💡 如扫描无结果，请使用上方「手动连接」输入 IP:端口直连';

  @override
  String homeScanFailed(Object error) {
    return '扫描失败：$error';
  }

  @override
  String get homeNoDevicesFound => '未扫描到设备。请确认上述条件，或改用「手动连接」。';

  @override
  String get homeServiceAdbTransport => 'ADB 传输';

  @override
  String get homeServiceTlsConnection => 'TLS 连接';

  @override
  String get homeServicePairing => '配对服务';

  @override
  String homeDeviceCount(int count) {
    return '设备（$count）';
  }

  @override
  String get homeRefreshAdbDevices => '刷新 ADB 设备列表';

  @override
  String homeAdbDevicesReadError(Object error) {
    return '无法读取 ADB 设备列表：$error';
  }

  @override
  String get homeNoAdbDevices => 'ADB Server 当前没有发现设备。';

  @override
  String get homeFireAdbConnected => 'FireAdb 已连接';

  @override
  String get commonDisconnect => '断开';

  @override
  String get homeUsbConnectionUnavailable => 'USB 连接暂不可用';

  @override
  String get homeDeviceOnline => '在线';

  @override
  String get homeDeviceOffline => '离线';

  @override
  String get homeDeviceUnauthorized => '未授权';

  @override
  String get homeDeviceBootloader => '引导加载程序';

  @override
  String get homeDeviceRecovery => '恢复模式';

  @override
  String get homeDeviceSideload => '侧载模式';

  @override
  String get homeDeviceUnknownState => '未知状态';

  @override
  String get homeHistoryConnections => '历史连接';

  @override
  String get homeNoHistory => '暂无历史记录';

  @override
  String get homeRemoveHistory => '移除历史';

  @override
  String get workspaceBackToHome => '返回主页';

  @override
  String get workspaceFeatures => '功能';

  @override
  String get workspaceDeviceDisconnectedTitle => '设备已断开连接';

  @override
  String get workspaceSwitchToOtherDevice => '切换到其他设备';

  @override
  String get workspaceBackToConnections => '返回连接页';

  @override
  String get workspaceOverviewTitle => '设备总览';

  @override
  String get workspaceOverviewDescription => '设备型号、品牌、系统版本等基本信息';

  @override
  String get workspaceAppsTitle => '设备应用';

  @override
  String get workspaceAppsDescription => '查看已安装应用、导出 APK、卸载与冻结';

  @override
  String get workspaceTransferTitle => '文件传输';

  @override
  String get workspaceTransferDescription => '推送文件到设备 / 从设备拉取文件';

  @override
  String get workspaceFilesTitle => '文件管理';

  @override
  String get workspaceFilesDescription =>
      '浏览设备文件，支持删除、重命名、复制粘贴、编辑、搜索、改权限，以及导出和从电脑上传';

  @override
  String get workspaceScreenshotTitle => '截图';

  @override
  String get workspaceScreenshotDescription => '调用 screencap -p 截取屏幕并保存 PNG';

  @override
  String get workspaceScreenrecordTitle => '录屏';

  @override
  String get workspaceScreenrecordDescription => '调用 screenrecord 录制设备屏幕';

  @override
  String get workspaceShellTitle => '命令面板';

  @override
  String get workspaceShellDescription => '执行 adb shell 命令并查看输出';

  @override
  String get workspacePlanned => '规划中';

  @override
  String get workspaceFeaturePlannedDescription => '该功能正在规划中，将在后续版本开放。';

  @override
  String get deviceOverviewModel => '设备型号';

  @override
  String get deviceOverviewManufacturer => '制造商';

  @override
  String get deviceOverviewBrand => '品牌';

  @override
  String get deviceOverviewAndroidVersion => 'Android 版本';

  @override
  String get deviceOverviewApiLevel => 'API 级别';

  @override
  String get deviceOverviewNotConnected => '设备未连接';

  @override
  String deviceOverviewNetworkConnection(Object host, int port) {
    return '网络连接 · $host:$port';
  }

  @override
  String get deviceOverviewConnected => '已连接';

  @override
  String deviceOverviewInfoReadFailed(Object error) {
    return '读取设备信息失败：$error';
  }

  @override
  String get deviceOverviewBasicInformation => '基本信息';

  @override
  String get shellOutputSettings => 'Shell 输出设置';

  @override
  String get shellDeviceNotConnected => '设备未连接';

  @override
  String shellMaxRetainedOutput(int limit) {
    return '最大保留输出：$limit MiB';
  }

  @override
  String get shellOutputLimitNote => '不限制行数；达到容量后仅移除较早的输出。';

  @override
  String get commonCancel => '取消';

  @override
  String get commonSave => '保存';

  @override
  String get commonSettingsSaveFailed => '保存设置失败';

  @override
  String get shellClearOutput => '清空输出';

  @override
  String get shellAbortCurrentCommand => '中止当前命令';

  @override
  String get shellSendCtrlC => '发送 Ctrl+C';

  @override
  String get shellEmptyPrompt =>
      '输入命令并按回车执行\n↑/↓ 浏览历史\n运行中可输入内容并回车发送；点击停止按钮中止\n常用: ls, ps, logcat, dumpsys, top, df';

  @override
  String get shellRunningHint => '向当前 Shell 输入内容并回车发送';

  @override
  String get shellCommandHint => '输入命令 (如: ls -la /sdcard)';

  @override
  String get shellInteractiveHint => '交互式 Shell · 输入 exit 结束';

  @override
  String get shellRunningSessionHint => '会话运行中 · 输入发送给当前进程';

  @override
  String get shellCommandAborted => '^C (已中止)';

  @override
  String shellCommandError(Object error) {
    return '错误: $error';
  }

  @override
  String shellSendInputFailed(Object error) {
    return '发送输入失败: $error';
  }

  @override
  String get shellEarlierOutputOmitted => '…较早的输出已省略…';

  @override
  String get appsSearchHint => '搜索应用名称或包名';

  @override
  String get appsFilterUser => '用户应用';

  @override
  String get appsFilterSystem => '系统应用';

  @override
  String get appsFilterFrozen => '已冻结';

  @override
  String get appsFilterAll => '全部';

  @override
  String get appsRefresh => '刷新应用列表';

  @override
  String appsCount(int count) {
    return '$count 个应用';
  }

  @override
  String get appsEmpty => '没有符合条件的应用';

  @override
  String appsLoadFailed(Object error) {
    return '读取应用列表失败：$error';
  }

  @override
  String appsVersion(Object version) {
    return '版本 $version';
  }

  @override
  String appsSize(Object size) {
    return '大小 $size';
  }

  @override
  String appsPath(Object path) {
    return '路径 $path';
  }

  @override
  String get appsFrozenBadge => '已冻结';

  @override
  String get appsDisabledBadge => '已停用';

  @override
  String get appsSuspendedBadge => '已暂停';

  @override
  String get appsAmFrozenBadge => 'AM 冻结';

  @override
  String get appsFreezeMethod => '冻结方式';

  @override
  String get appsFreezeTitle => '冻结应用';

  @override
  String get appsUnfreezeTitle => '解冻应用';

  @override
  String appsFreezePrompt(Object name) {
    return '选择冻结 $name 的方式';
  }

  @override
  String appsUnfreezePrompt(Object name) {
    return '选择解除 $name 冻结的方式';
  }

  @override
  String get appsFreezeMethodDisableUser => '停用应用';

  @override
  String get appsFreezeMethodDisableUserDescription =>
      'pm disable-user：用户停用，应用无法启动。适配范围最广。';

  @override
  String get appsFreezeMethodSuspend => '暂停应用';

  @override
  String get appsFreezeMethodSuspendDescription =>
      'pm suspend：暂停并隐藏应用，数据保留，可随时恢复。';

  @override
  String get appsFreezeMethodAmFreeze => 'AM 冻结';

  @override
  String get appsFreezeMethodAmFreezeDescription =>
      'am freeze：由 ActivityManager 冻结进程，需要 Android 15+。';

  @override
  String get appsExportAction => '导出 APK';

  @override
  String get appsExportTitle => '导出应用';

  @override
  String appsExportPrompt(Object name) {
    return '请输入要将 $name 拉取到的目标目录';
  }

  @override
  String get appsExportDirectory => '目标目录';

  @override
  String appsExportSucceeded(Object path) {
    return '已导出到 $path';
  }

  @override
  String get appsUninstallAction => '卸载';

  @override
  String get appsUninstallTitle => '卸载应用';

  @override
  String appsUninstallConfirm(Object name, Object packageName) {
    return '确定卸载 $name（$packageName）吗？';
  }

  @override
  String get appsUninstallSystemTitle => '卸载系统应用';

  @override
  String appsUninstallSystemConfirm(Object name, Object packageName) {
    return '$name（$packageName）是系统应用。卸载后可能影响相关功能，且通常很难恢复。确定继续吗？';
  }

  @override
  String get appsUninstallCoreTitle => '卸载核心系统应用';

  @override
  String appsUninstallCoreConfirm(Object name, Object packageName) {
    return '$name（$packageName）是核心系统组件。卸载后可能导致无法开机、没有桌面、无法拨号或无法打开设置，且很难恢复。确定仍要卸载吗？';
  }

  @override
  String get appsUninstallConfirmAction => '仍然卸载';

  @override
  String appsUninstallSucceeded(Object name) {
    return '已卸载 $name';
  }

  @override
  String get appsFreezeSystemTitle => '冻结系统应用';

  @override
  String appsFreezeSystemConfirm(Object name, Object packageName) {
    return '$name（$packageName）是系统应用。冻结后可能影响相关功能，确定继续吗？';
  }

  @override
  String get appsFreezeCoreTitle => '冻结核心系统应用';

  @override
  String appsFreezeCoreConfirm(Object name, Object packageName) {
    return '$name（$packageName）是核心系统组件。冻结后可能导致无法开机、没有桌面、无法拨号或无法打开设置。确定仍要冻结吗？';
  }

  @override
  String get appsFreezeConfirmAction => '仍然冻结';

  @override
  String get appsFreezeAction => '冻结';

  @override
  String get appsUnfreezeAction => '解冻';

  @override
  String appsFreezeSucceeded(Object name) {
    return '已冻结 $name';
  }

  @override
  String appsUnfreezeSucceeded(Object name) {
    return '已解冻 $name';
  }

  @override
  String get appsActionFailed => '操作失败';

  @override
  String get appsSelect => '多选';

  @override
  String get appsSelectDone => '完成';

  @override
  String get appsSelectAll => '全选';

  @override
  String get appsSelectClear => '取消选择';

  @override
  String appsSelectedCount(int count) {
    return '已选 $count 个';
  }

  @override
  String appsBatchUninstallConfirm(int count) {
    return '确定卸载选中的 $count 个应用吗？';
  }

  @override
  String appsBatchUninstallSystemConfirm(int count, Object names) {
    return '选中的 $count 个应用包含系统应用（$names）。卸载后可能影响相关功能，且通常很难恢复。确定继续吗？';
  }

  @override
  String appsBatchUninstallCoreConfirm(int count, Object names) {
    return '选中的 $count 个应用包含核心系统组件（$names）。卸载后可能导致无法开机、没有桌面、无法拨号或无法打开设置，且很难恢复。确定仍要卸载吗？';
  }

  @override
  String appsBatchFreezeConfirm(int count) {
    return '确定冻结选中的 $count 个应用吗？';
  }

  @override
  String appsBatchFreezeSystemConfirm(int count, Object names) {
    return '选中的 $count 个应用包含系统应用（$names）。冻结后可能影响相关功能，确定继续吗？';
  }

  @override
  String appsBatchFreezeCoreConfirm(int count, Object names) {
    return '选中的 $count 个应用包含核心系统组件（$names）。冻结后可能导致无法开机、没有桌面、无法拨号或无法打开设置。确定仍要冻结吗？';
  }

  @override
  String appsBatchExportPrompt(int count) {
    return '请输入要将选中的 $count 个应用拉取到的目标目录';
  }

  @override
  String appsBatchUninstallSucceeded(int count) {
    return '已卸载 $count 个应用';
  }

  @override
  String appsBatchFreezeSucceeded(int count) {
    return '已冻结 $count 个应用';
  }

  @override
  String appsBatchExportSucceeded(int count, Object path) {
    return '已导出 $count 个应用到 $path';
  }

  @override
  String get appsTaskExport => '正在导出';

  @override
  String get appsTaskUninstall => '正在卸载';

  @override
  String get appsTaskFreeze => '正在冻结';

  @override
  String get appsTaskUnfreeze => '正在解冻';

  @override
  String appsTaskProgress(
    Object action,
    Object name,
    int completed,
    int total,
    int percent,
  ) {
    return '$action $name（$completed/$total，$percent%）';
  }

  @override
  String get appsExportMeasuring => '正在计算大小…';

  @override
  String appsExportBytes(Object done, Object total) {
    return '$done / $total';
  }

  @override
  String appsExportPercent(int percent) {
    return '$percent%';
  }

  @override
  String get appsCancelTask => '取消';

  @override
  String get appsTaskCancelled => '已取消';

  @override
  String appsTaskCancelledDone(int count) {
    return '已取消，已完成 $count 个';
  }

  @override
  String appsBatchPartial(int succeeded, int failed) {
    return '成功 $succeeded 个，失败 $failed 个';
  }

  @override
  String get filesPath => '设备路径';

  @override
  String get filesUp => '上级目录';

  @override
  String get filesRefresh => '刷新';

  @override
  String get filesUpload => '上传';

  @override
  String get filesCreate => '新建';

  @override
  String get filesFile => '文件';

  @override
  String get filesFolder => '文件夹';

  @override
  String get filesLink => '链接';

  @override
  String get filesName => '名称';

  @override
  String get filesSearch => '搜索';

  @override
  String get filesSearchHint => '在当前目录中按名称搜索';

  @override
  String get filesClearSearch => '清除搜索';

  @override
  String filesSearching(Object keyword) {
    return '正在显示“$keyword”的搜索结果';
  }

  @override
  String get filesSearchEmpty => '没有匹配的文件';

  @override
  String get filesEmpty => '这个目录是空的';

  @override
  String get filesSelect => '多选';

  @override
  String get filesClearSelection => '取消多选';

  @override
  String get filesSelectAll => '全选';

  @override
  String get filesOpen => '打开';

  @override
  String get filesDelete => '删除';

  @override
  String filesDeleteConfirm(Object name) {
    return '删除 $name？此操作不可恢复';
  }

  @override
  String filesBatchDeleteConfirm(int count) {
    return '删除选中的 $count 项？此操作不可恢复';
  }

  @override
  String filesDeleted(int count) {
    return '已删除 $count 项';
  }

  @override
  String get filesRename => '重命名';

  @override
  String get filesRenamed => '已重命名';

  @override
  String get filesInvalidName => '名称不能为空，也不能包含 /';

  @override
  String get filesCopy => '复制';

  @override
  String get filesCut => '剪切';

  @override
  String get filesPaste => '粘贴';

  @override
  String get filesPasteIntoSelf => '不能把目录粘贴到它自己里面';

  @override
  String filesPasted(int count) {
    return '已粘贴 $count 项';
  }

  @override
  String filesClipboardCopied(int count) {
    return '已复制 $count 项，可粘贴到其他目录';
  }

  @override
  String filesClipboardCut(int count) {
    return '已剪切 $count 项，可粘贴到其他目录';
  }

  @override
  String get filesEdit => '编辑';

  @override
  String filesEditTitle(Object name) {
    return '编辑 $name';
  }

  @override
  String get filesEditTooLarge => '文件超过 512 KB，不能在这里编辑';

  @override
  String get filesEditBinary => '这不是文本文件';

  @override
  String get filesSaved => '已保存';

  @override
  String get filesPermission => '权限';

  @override
  String get filesPermissionHint => '八进制权限，例如 644';

  @override
  String get filesInvalidPermission => '请输入 3 到 4 位八进制权限';

  @override
  String get filesPermissionUpdated => '已修改权限';

  @override
  String filesCreated(Object name) {
    return '已创建 $name';
  }

  @override
  String get filesExport => '导出';

  @override
  String filesExportPrompt(Object name) {
    return '请输入要将 $name 导出到的目录';
  }

  @override
  String filesBatchExportPrompt(int count) {
    return '请输入要将选中的 $count 项导出到的目录';
  }

  @override
  String filesExportSucceeded(Object path) {
    return '已导出到 $path';
  }

  @override
  String filesUploadSucceeded(int count) {
    return '已上传 $count 个文件';
  }

  @override
  String filesOverwrite(Object names) {
    return '目标目录已有同名文件，上传将覆盖：$names';
  }

  @override
  String filesLoadFailed(Object error) {
    return '读取目录失败：$error';
  }

  @override
  String get filesActionFailed => '操作失败';

  @override
  String get filesTaskDelete => '正在删除';

  @override
  String get filesTaskRename => '正在重命名';

  @override
  String get filesTaskCopy => '正在复制';

  @override
  String get filesTaskMove => '正在移动';

  @override
  String get filesTaskExport => '正在导出';

  @override
  String get filesTaskUpload => '正在上传';

  @override
  String get filesTaskSave => '正在保存';

  @override
  String get filesLocationsStorage => '内部存储';

  @override
  String get filesLocationsTemp => '临时目录';

  @override
  String get filesLocationsRoot => '根目录';
}
