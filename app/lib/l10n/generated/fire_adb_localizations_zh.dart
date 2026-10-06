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
  String get workspaceAppsDescription => '查看已安装应用、卸载应用、安装 APK';

  @override
  String get workspaceTransferTitle => '文件传输';

  @override
  String get workspaceTransferDescription => '推送文件到设备 / 从设备拉取文件';

  @override
  String get workspaceFilesTitle => '文件管理';

  @override
  String get workspaceFilesDescription => '浏览设备存储，下载、删除、分享文件';

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
}
