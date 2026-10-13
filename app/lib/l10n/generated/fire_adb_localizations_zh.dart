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
  String get settingsTitle => '设置';

  @override
  String get settingsPreferSdkAdb => '优先使用 SDK 的 adb server';

  @override
  String get settingsChooseLanguage => '选择语言';

  @override
  String get settingsAdbServerPort => 'FireAdb server 端口';

  @override
  String get settingsAdbServerPortHelp =>
      '默认 5037。应用后，FireAdb 在新端口重新启动自己的 server，本应用的设备列表连到这里。其他 adb 客户端仍去连接 5037 上的 adb server；5037 上没有服务时，adb 会自己在 5037 起一个。';

  @override
  String get settingsApply => '应用';

  @override
  String get settingsAdbServerPortInvalid => '请输入 1 到 65535 之间的端口';

  @override
  String get settingsPreferSdkAdbHelp => '在电脑上找到 adb 后，由它在上面的端口启动，不再由本进程监听。';

  @override
  String settingsSdkAdbPath(Object path) {
    return '已找到 $path';
  }

  @override
  String get settingsSdkAdbMissing => '未找到 adb，仍使用 FireAdb 的 server。';

  @override
  String settingsSdkAdbStartFailed(Object error) {
    return '启动 SDK 的 adb server 失败：$error';
  }

  @override
  String settingsLanguageSaveFailed(Object error) {
    return '保存语言设置失败：$error';
  }

  @override
  String get settingsAutoRefreshMdns => '自动刷新 mDNS';

  @override
  String get settingsAutoRefreshDevices => '自动刷新设备列表';

  @override
  String settingsAutoRefreshHelp(int seconds) {
    return '勾选后每 $seconds 秒刷新一次';
  }

  @override
  String get settingsAutoRefreshInterval => '刷新间隔（秒）';

  @override
  String get settingsAutoRefreshIntervalInvalid => '请输入 1 到 3600 之间的整数';

  @override
  String get settingsRefreshInBackground => '后台刷新';

  @override
  String get settingsRefreshInBackgroundHelp => '关闭时，连接页不在最前面或应用进入后台，自动刷新会停下来。';

  @override
  String get settingsLogDirectory => '日志目录';

  @override
  String get settingsOpenLogDirectory => '在文件管理器中打开';

  @override
  String get settingsLogDirectoryUnavailable => '日志目录还不可用';

  @override
  String settingsOpenLogDirectoryFailed(Object error) {
    return '无法打开日志目录：$error';
  }

  @override
  String get settingsLogBuffer => '日志显示缓冲区（KB）';

  @override
  String get settingsLogBufferHelp => '日志页在内存中保留这些内容，默认 256 KB。';

  @override
  String get settingsLogBufferInvalid => '请输入 16 到 8192 之间的整数';

  @override
  String get settingsLogRetention => '日志保存天数';

  @override
  String get settingsLogRetentionHelp => '启动时删除早于这个天数的日志文件。默认 7 天。';

  @override
  String get settingsLogRetentionInvalid => '请输入 1 到 365 之间的整数';

  @override
  String get settingsLogDeleteAll => '一键清理';

  @override
  String get settingsLogDeleteAllTitle => '清理日志文件';

  @override
  String get settingsLogDeleteAllMessage =>
      '删除日志目录中的全部日志文件？正在写入的文件会重新开始，页面上已显示的内容保留。';

  @override
  String settingsLogDeleteAllFailed(Object error) {
    return '清理日志文件失败：$error';
  }

  @override
  String get homeAutoRefresh => '自动刷新';

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
      '在手机上打开系统「设置 → 开发者选项 → 无线调试 → 使用配对码配对设备」，并保持该页面打开。在安卓端连接本机时，可能无法停留在数字配对码页面，请使用悬浮窗或分屏，避免配对服务关闭导致无法连接。\n设备列表刷新时会扫描无线服务。对这里出现的配对服务点「配对」并输入手机上的配对码。能连接的无线设备会出现在设备列表中，在那里连接。';

  @override
  String get homePairingCodeGuideTitle => '配对码配对：';

  @override
  String get homeQrPairingGuideTitle => '二维码配对：';

  @override
  String get homeQrPairingGuide =>
      '在本页点「二维码配对」。手机打开系统「设置 → 开发者选项 → 无线调试 → 使用二维码配对设备」，扫描本页弹出的二维码。本应用会自动完成配对并连接。';

  @override
  String homeScanFailed(Object error) {
    return '扫描失败：$error';
  }

  @override
  String get homeNoDevicesFound => '未扫描到当前设备，请确认当前设备';

  @override
  String get homeDiscoveredDevicesInList => '能连接的无线设备已放在设备列表中。';

  @override
  String get homeServiceAdbTransport => 'ADB 传输';

  @override
  String get homeServiceTlsConnection => 'TLS 连接';

  @override
  String get homeServicePairing => '配对服务';

  @override
  String get homePair => '配对';

  @override
  String get homePairingTitle => '无线配对';

  @override
  String get homePairingCodeHelp => '输入无线调试页面上的配对码。';

  @override
  String get homePairingSucceeded => '配对成功';

  @override
  String get homePairingSucceededHint => '能连接的无线设备会出现在设备列表中，在那里连接。';

  @override
  String get homeQrPair => '二维码配对';

  @override
  String get homeQrPairingTitle => '二维码配对';

  @override
  String get homeQrPairingPrinciple =>
      '二维码里是服务名和配对密码。手机扫码后会用这个名字发布配对服务，本应用找到同名服务后用该密码完成配对，再连接无线调试端口。';

  @override
  String get homeQrPairingHelp =>
      '在手机上打开「设置 → 开发者选项 → 无线调试 → 使用二维码配对设备」，扫描此二维码。手机与本应用需在同一 Wi-Fi。';

  @override
  String get homeQrPairingWaiting => '等待手机扫描…';

  @override
  String get homeQrPairingPairing => '正在配对…';

  @override
  String get homeQrPairingConnecting => '配对成功，正在连接…';

  @override
  String get homeQrPairingTimeout => '没有等到手机扫描。请确认无线调试已打开，然后重试。';

  @override
  String homeQrPairingFailed(Object error) {
    return '二维码配对失败：$error';
  }

  @override
  String homeDeviceCount(int count) {
    return '设备（$count）';
  }

  @override
  String get homeRefreshAdbDevices => '刷新设备列表';

  @override
  String homeAdbDevicesReadError(Object error) {
    return '无法读取 ADB 设备列表：$error';
  }

  @override
  String homeUsbDevicesReadError(Object error) {
    return '无法读取 USB 设备：$error';
  }

  @override
  String get homeNoAdbDevices => 'ADB Server 当前没有发现设备。';

  @override
  String get homeAdbServerUnavailable => '本机 ADB Server 不可用，设备列表无法刷新。';

  @override
  String homeAdbServerNotRunning(Object port) {
    return '本机没有 ADB Server（127.0.0.1:$port）。USB 设备会直接列出，网络设备请手动连接或扫描。';
  }

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
  String get workspaceDevices => '设备';

  @override
  String get workspaceConnectDevice => '连接设备';

  @override
  String get workspaceConnectedDevices => '已连接';

  @override
  String get workspaceAvailableDevices => '可连接';

  @override
  String get workspaceNoAvailableDevices => '没有其他可连接的设备';

  @override
  String get workspaceOtherConnections => '其他连接方式';

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
  String get workspaceScreenshotDescription =>
      '调用 screencap -p 截取屏幕，并把 PNG 保存到应用目录';

  @override
  String get workspaceScreenrecordTitle => '录屏';

  @override
  String get workspaceScreenrecordDescription => '录制屏幕并保存到应用目录，可选用系统或内置录屏';

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
  String get commonClose => '关闭';

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
    return '选择要将 $name 拉取到的目录';
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
    return '选择要将选中的 $count 个应用拉取到的目录';
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
    return '选择要将 $name 导出到的目录';
  }

  @override
  String filesBatchExportPrompt(int count) {
    return '选择要将选中的 $count 项导出到的目录';
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

  @override
  String get captureDirectoryUnavailable => '找不到应用目录，无法保存文件';

  @override
  String captureSaved(Object path) {
    return '已保存到 $path';
  }

  @override
  String get captureSaveLocation => '保存位置';

  @override
  String get captureOpenFolder => '打开应用目录';

  @override
  String get captureOpenFile => '打开';

  @override
  String captureOpenFailed(Object error) {
    return '无法打开：$error';
  }

  @override
  String get captureRefresh => '刷新';

  @override
  String get captureDelete => '删除';

  @override
  String captureDeleteConfirm(Object name) {
    return '从应用目录删除 $name？';
  }

  @override
  String captureDeleted(Object name) {
    return '已删除 $name';
  }

  @override
  String get captureActionFailed => '操作失败';

  @override
  String captureDeviceOutput(Object output) {
    return '设备输出：$output';
  }

  @override
  String captureFailedWithRemote(Object error, Object path) {
    return '$error。设备上的临时文件仍在 $path';
  }

  @override
  String get captureEmptyScreenshots => '应用目录里还没有截图';

  @override
  String get captureEmptyRecordings => '应用目录里还没有录像';

  @override
  String get screenshotCapture => '截取屏幕';

  @override
  String get screenshotCapturing => '正在截取屏幕…';

  @override
  String get screenshotInvalid => '设备没有返回有效的 PNG';

  @override
  String get screenrecordStart => '开始录屏';

  @override
  String get screenrecordStop => '停止并保存';

  @override
  String get screenrecordSaving => '正在保存到应用目录…';

  @override
  String get screenrecordRecording => '正在录制';

  @override
  String get screenrecordTimeLimit => '时长上限';

  @override
  String get screenrecordLimit30 => '30 秒';

  @override
  String get screenrecordLimit60 => '1 分钟';

  @override
  String get screenrecordLimit180 => '3 分钟';

  @override
  String get screenrecordLimitNone => '不限时';

  @override
  String get screenrecordTimeLimitNote => 'Android 13 及更早版本最长 3 分钟，超过会被系统拒绝。';

  @override
  String get screenrecordTimeLimitUnlimited => '这台设备不限制最长时长，可以选择不限时。';

  @override
  String get screenrecordHint => '停止后保存到应用目录，并删除设备上的临时视频。';

  @override
  String get screenrecordMethod => '录制方式';

  @override
  String get screenrecordMethodSystem => '系统录屏';

  @override
  String get screenrecordMethodSystemSubtitle => '调用设备自带的 screenrecord';

  @override
  String get screenrecordMethodBuiltin => '内置录屏';

  @override
  String get screenrecordMethodBuiltinSubtitle => '用辅助服务编码，画面直接送进编码器。';

  @override
  String get screenrecordMethodScrcpy => '投屏录屏';

  @override
  String get screenrecordMethodScrcpySubtitle => '即将支持。同一条连接以后用于画面预览和远程操作。';

  @override
  String get screenrecordShellCopyFailed => '无法准备临时目录里的录屏程序';

  @override
  String get screenrecordShellUnsafe => '临时目录里的录屏程序仍会被系统策略接管，已取消执行，文件仍留在原地';

  @override
  String get screenrecordTimeLimitBuiltin => '内置录屏不限制最长时长，可以选择不限时。';

  @override
  String get screenrecordNoWritableDir => 'shell 无法以读写方式创建录像文件';

  @override
  String get screenrecordMissing => '设备上没有生成录像文件';

  @override
  String screenrecordInvalid(Object path) {
    return '录像文件无效，仍留在设备上：$path';
  }

  @override
  String screenrecordTooLarge(Object size, Object path) {
    return '录像有 $size，超过可保存的大小，仍留在设备上：$path';
  }

  @override
  String get storageAccessTitle => '需要文件访问权限';

  @override
  String get storageAccessMessage => '浏览和保存手机上的目录需要授予「所有文件访问权限」。';

  @override
  String get storageAccessGrant => '去授权';

  @override
  String get localPickerChooseFolder => '选择文件夹';

  @override
  String get localPickerChooseFiles => '选择文件';

  @override
  String get localPickerUseFolder => '选择此文件夹';

  @override
  String localPickerUseFiles(int count) {
    return '选择（$count）';
  }

  @override
  String get localPickerStorage => '存储设备';

  @override
  String get localPickerInternalStorage => '内部存储';

  @override
  String get localPickerEmpty => '此目录是空的';

  @override
  String get localPickerUnreadable => '无法读取此目录';

  @override
  String get localPickerNewFolder => '新建文件夹';

  @override
  String get localPickerInvalidName => '名称不能包含 / 或 \\';

  @override
  String get localPickerUp => '上级目录';

  @override
  String get localPickerGo => '前往';

  @override
  String get navConnection => '连接';

  @override
  String get navLogs => '日志';

  @override
  String get navAbout => '关于';

  @override
  String get logClear => '清理';

  @override
  String get logClearTitle => '清理日志';

  @override
  String get logClearMessage => '只清除当前显示的内容？日志文件仍会保留。';

  @override
  String get logEmpty => '还没有日志';

  @override
  String get logRefresh => '刷新';

  @override
  String get logTruncated => '较早的日志未在此显示，仅保留末尾。';

  @override
  String logClearFailed(Object error) {
    return '清理日志失败：$error';
  }

  @override
  String logReadFailed(Object error) {
    return '读取日志失败：$error';
  }

  @override
  String aboutVersion(Object version) {
    return '版本 $version';
  }

  @override
  String aboutBuild(Object build) {
    return '构建号 $build';
  }

  @override
  String get aboutDescription => '跨平台 ADB 工具箱。协议自实现，不依赖系统 adb。';

  @override
  String get aboutVersionUnknown => '版本信息还不可用';
}
