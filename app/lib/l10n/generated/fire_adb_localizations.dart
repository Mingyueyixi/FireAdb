import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'fire_adb_localizations_en.dart';
import 'fire_adb_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of FireAdbLocalizations
/// returned by `FireAdbLocalizations.of(context)`.
///
/// Applications need to include `FireAdbLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/fire_adb_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: FireAdbLocalizations.localizationsDelegates,
///   supportedLocales: FireAdbLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the FireAdbLocalizations.supportedLocales
/// property.
abstract class FireAdbLocalizations {
  FireAdbLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static FireAdbLocalizations? of(BuildContext context) {
    return Localizations.of<FireAdbLocalizations>(
      context,
      FireAdbLocalizations,
    );
  }

  static const LocalizationsDelegate<FireAdbLocalizations> delegate =
      _FireAdbLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en'),
  ];

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguage;

  /// No description provided for @settingsChinese.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get settingsChinese;

  /// No description provided for @settingsEnglish.
  ///
  /// In zh, this message translates to:
  /// **'英文'**
  String get settingsEnglish;

  /// No description provided for @settingsLanguageSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存语言设置失败：{error}'**
  String settingsLanguageSaveFailed(Object error);

  /// No description provided for @homeConnectionSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'连接成功'**
  String get homeConnectionSucceeded;

  /// No description provided for @homeConnectedDevice.
  ///
  /// In zh, this message translates to:
  /// **'已连接：{serial}'**
  String homeConnectedDevice(Object serial);

  /// No description provided for @homeConnectionFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get homeConnectionFailed;

  /// No description provided for @homeInvalidInput.
  ///
  /// In zh, this message translates to:
  /// **'输入无效'**
  String get homeInvalidInput;

  /// No description provided for @homeInvalidHostPort.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的主机地址与端口（1-65535）'**
  String get homeInvalidHostPort;

  /// No description provided for @homeDeviceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'设备不可用'**
  String get homeDeviceUnavailable;

  /// No description provided for @homeAdbDeviceMissing.
  ///
  /// In zh, this message translates to:
  /// **'该设备当前未出现在 ADB 设备列表中，请先连接设备并刷新列表。'**
  String get homeAdbDeviceMissing;

  /// No description provided for @homeDeviceDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'设备已断开'**
  String get homeDeviceDisconnected;

  /// No description provided for @homeDisconnectSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已断开连接'**
  String get homeDisconnectSucceeded;

  /// No description provided for @homeDisconnectFailed.
  ///
  /// In zh, this message translates to:
  /// **'断开失败'**
  String get homeDisconnectFailed;

  /// No description provided for @homeManualConnection.
  ///
  /// In zh, this message translates to:
  /// **'手动连接'**
  String get homeManualConnection;

  /// No description provided for @homeHostAddress.
  ///
  /// In zh, this message translates to:
  /// **'主机地址'**
  String get homeHostAddress;

  /// No description provided for @homeHostAddressExample.
  ///
  /// In zh, this message translates to:
  /// **'例如 192.168.1.100'**
  String get homeHostAddressExample;

  /// No description provided for @homePort.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get homePort;

  /// No description provided for @homeConnecting.
  ///
  /// In zh, this message translates to:
  /// **'连接中…'**
  String get homeConnecting;

  /// No description provided for @commonConnect.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get commonConnect;

  /// No description provided for @homeDeviceDiscovery.
  ///
  /// In zh, this message translates to:
  /// **'设备发现（mDNS）'**
  String get homeDeviceDiscovery;

  /// No description provided for @homeScanning.
  ///
  /// In zh, this message translates to:
  /// **'扫描中…'**
  String get homeScanning;

  /// No description provided for @homeScan.
  ///
  /// In zh, this message translates to:
  /// **'扫描'**
  String get homeScan;

  /// No description provided for @homeWifiDebugInfo.
  ///
  /// In zh, this message translates to:
  /// **'仅适用于开启「无线调试」的 Android 11+ 设备'**
  String get homeWifiDebugInfo;

  /// No description provided for @homeMdnsHelp.
  ///
  /// In zh, this message translates to:
  /// **'✅ 能发现：\n• 设置 → 开发者选项 → 无线调试 → 已开启\n• 手机与电脑在同一 Wi-Fi（无 AP 隔离）\n\n❌ 无法发现：\n• 仅开启 USB 调试、未开无线调试\n• 通过 `adb connect IP:PORT` 手动连接的设备\n• Android 11 以下或未实现 mDNS 广播的 ROM\n\n💡 如扫描无结果，请使用上方「手动连接」输入 IP:端口直连'**
  String get homeMdnsHelp;

  /// No description provided for @homeScanFailed.
  ///
  /// In zh, this message translates to:
  /// **'扫描失败：{error}'**
  String homeScanFailed(Object error);

  /// No description provided for @homeNoDevicesFound.
  ///
  /// In zh, this message translates to:
  /// **'未扫描到设备。请确认上述条件，或改用「手动连接」。'**
  String get homeNoDevicesFound;

  /// No description provided for @homeServiceAdbTransport.
  ///
  /// In zh, this message translates to:
  /// **'ADB 传输'**
  String get homeServiceAdbTransport;

  /// No description provided for @homeServiceTlsConnection.
  ///
  /// In zh, this message translates to:
  /// **'TLS 连接'**
  String get homeServiceTlsConnection;

  /// No description provided for @homeServicePairing.
  ///
  /// In zh, this message translates to:
  /// **'配对服务'**
  String get homeServicePairing;

  /// No description provided for @homeDeviceCount.
  ///
  /// In zh, this message translates to:
  /// **'设备（{count}）'**
  String homeDeviceCount(int count);

  /// No description provided for @homeRefreshAdbDevices.
  ///
  /// In zh, this message translates to:
  /// **'刷新 ADB 设备列表'**
  String get homeRefreshAdbDevices;

  /// No description provided for @homeAdbDevicesReadError.
  ///
  /// In zh, this message translates to:
  /// **'无法读取 ADB 设备列表：{error}'**
  String homeAdbDevicesReadError(Object error);

  /// No description provided for @homeNoAdbDevices.
  ///
  /// In zh, this message translates to:
  /// **'ADB Server 当前没有发现设备。'**
  String get homeNoAdbDevices;

  /// No description provided for @homeFireAdbConnected.
  ///
  /// In zh, this message translates to:
  /// **'FireAdb 已连接'**
  String get homeFireAdbConnected;

  /// No description provided for @commonDisconnect.
  ///
  /// In zh, this message translates to:
  /// **'断开'**
  String get commonDisconnect;

  /// No description provided for @homeUsbConnectionUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'USB 连接暂不可用'**
  String get homeUsbConnectionUnavailable;

  /// No description provided for @homeDeviceOnline.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get homeDeviceOnline;

  /// No description provided for @homeDeviceOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get homeDeviceOffline;

  /// No description provided for @homeDeviceUnauthorized.
  ///
  /// In zh, this message translates to:
  /// **'未授权'**
  String get homeDeviceUnauthorized;

  /// No description provided for @homeDeviceBootloader.
  ///
  /// In zh, this message translates to:
  /// **'引导加载程序'**
  String get homeDeviceBootloader;

  /// No description provided for @homeDeviceRecovery.
  ///
  /// In zh, this message translates to:
  /// **'恢复模式'**
  String get homeDeviceRecovery;

  /// No description provided for @homeDeviceSideload.
  ///
  /// In zh, this message translates to:
  /// **'侧载模式'**
  String get homeDeviceSideload;

  /// No description provided for @homeDeviceUnknownState.
  ///
  /// In zh, this message translates to:
  /// **'未知状态'**
  String get homeDeviceUnknownState;

  /// No description provided for @homeHistoryConnections.
  ///
  /// In zh, this message translates to:
  /// **'历史连接'**
  String get homeHistoryConnections;

  /// No description provided for @homeNoHistory.
  ///
  /// In zh, this message translates to:
  /// **'暂无历史记录'**
  String get homeNoHistory;

  /// No description provided for @homeRemoveHistory.
  ///
  /// In zh, this message translates to:
  /// **'移除历史'**
  String get homeRemoveHistory;

  /// No description provided for @workspaceBackToHome.
  ///
  /// In zh, this message translates to:
  /// **'返回主页'**
  String get workspaceBackToHome;

  /// No description provided for @workspaceFeatures.
  ///
  /// In zh, this message translates to:
  /// **'功能'**
  String get workspaceFeatures;

  /// No description provided for @workspaceDeviceDisconnectedTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备已断开连接'**
  String get workspaceDeviceDisconnectedTitle;

  /// No description provided for @workspaceSwitchToOtherDevice.
  ///
  /// In zh, this message translates to:
  /// **'切换到其他设备'**
  String get workspaceSwitchToOtherDevice;

  /// No description provided for @workspaceBackToConnections.
  ///
  /// In zh, this message translates to:
  /// **'返回连接页'**
  String get workspaceBackToConnections;

  /// No description provided for @workspaceOverviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备总览'**
  String get workspaceOverviewTitle;

  /// No description provided for @workspaceOverviewDescription.
  ///
  /// In zh, this message translates to:
  /// **'设备型号、品牌、系统版本等基本信息'**
  String get workspaceOverviewDescription;

  /// No description provided for @workspaceAppsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备应用'**
  String get workspaceAppsTitle;

  /// No description provided for @workspaceAppsDescription.
  ///
  /// In zh, this message translates to:
  /// **'查看已安装应用、导出 APK、卸载与冻结'**
  String get workspaceAppsDescription;

  /// No description provided for @workspaceTransferTitle.
  ///
  /// In zh, this message translates to:
  /// **'文件传输'**
  String get workspaceTransferTitle;

  /// No description provided for @workspaceTransferDescription.
  ///
  /// In zh, this message translates to:
  /// **'推送文件到设备 / 从设备拉取文件'**
  String get workspaceTransferDescription;

  /// No description provided for @workspaceFilesTitle.
  ///
  /// In zh, this message translates to:
  /// **'文件管理'**
  String get workspaceFilesTitle;

  /// No description provided for @workspaceFilesDescription.
  ///
  /// In zh, this message translates to:
  /// **'浏览设备存储，下载、删除、分享文件'**
  String get workspaceFilesDescription;

  /// No description provided for @workspaceScreenshotTitle.
  ///
  /// In zh, this message translates to:
  /// **'截图'**
  String get workspaceScreenshotTitle;

  /// No description provided for @workspaceScreenshotDescription.
  ///
  /// In zh, this message translates to:
  /// **'调用 screencap -p 截取屏幕并保存 PNG'**
  String get workspaceScreenshotDescription;

  /// No description provided for @workspaceScreenrecordTitle.
  ///
  /// In zh, this message translates to:
  /// **'录屏'**
  String get workspaceScreenrecordTitle;

  /// No description provided for @workspaceScreenrecordDescription.
  ///
  /// In zh, this message translates to:
  /// **'调用 screenrecord 录制设备屏幕'**
  String get workspaceScreenrecordDescription;

  /// No description provided for @workspaceShellTitle.
  ///
  /// In zh, this message translates to:
  /// **'命令面板'**
  String get workspaceShellTitle;

  /// No description provided for @workspaceShellDescription.
  ///
  /// In zh, this message translates to:
  /// **'执行 adb shell 命令并查看输出'**
  String get workspaceShellDescription;

  /// No description provided for @workspacePlanned.
  ///
  /// In zh, this message translates to:
  /// **'规划中'**
  String get workspacePlanned;

  /// No description provided for @workspaceFeaturePlannedDescription.
  ///
  /// In zh, this message translates to:
  /// **'该功能正在规划中，将在后续版本开放。'**
  String get workspaceFeaturePlannedDescription;

  /// No description provided for @deviceOverviewModel.
  ///
  /// In zh, this message translates to:
  /// **'设备型号'**
  String get deviceOverviewModel;

  /// No description provided for @deviceOverviewManufacturer.
  ///
  /// In zh, this message translates to:
  /// **'制造商'**
  String get deviceOverviewManufacturer;

  /// No description provided for @deviceOverviewBrand.
  ///
  /// In zh, this message translates to:
  /// **'品牌'**
  String get deviceOverviewBrand;

  /// No description provided for @deviceOverviewAndroidVersion.
  ///
  /// In zh, this message translates to:
  /// **'Android 版本'**
  String get deviceOverviewAndroidVersion;

  /// No description provided for @deviceOverviewApiLevel.
  ///
  /// In zh, this message translates to:
  /// **'API 级别'**
  String get deviceOverviewApiLevel;

  /// No description provided for @deviceOverviewNotConnected.
  ///
  /// In zh, this message translates to:
  /// **'设备未连接'**
  String get deviceOverviewNotConnected;

  /// No description provided for @deviceOverviewNetworkConnection.
  ///
  /// In zh, this message translates to:
  /// **'网络连接 · {host}:{port}'**
  String deviceOverviewNetworkConnection(Object host, int port);

  /// No description provided for @deviceOverviewConnected.
  ///
  /// In zh, this message translates to:
  /// **'已连接'**
  String get deviceOverviewConnected;

  /// No description provided for @deviceOverviewInfoReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取设备信息失败：{error}'**
  String deviceOverviewInfoReadFailed(Object error);

  /// No description provided for @deviceOverviewBasicInformation.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get deviceOverviewBasicInformation;

  /// No description provided for @shellOutputSettings.
  ///
  /// In zh, this message translates to:
  /// **'Shell 输出设置'**
  String get shellOutputSettings;

  /// No description provided for @shellDeviceNotConnected.
  ///
  /// In zh, this message translates to:
  /// **'设备未连接'**
  String get shellDeviceNotConnected;

  /// No description provided for @shellMaxRetainedOutput.
  ///
  /// In zh, this message translates to:
  /// **'最大保留输出：{limit} MiB'**
  String shellMaxRetainedOutput(int limit);

  /// No description provided for @shellOutputLimitNote.
  ///
  /// In zh, this message translates to:
  /// **'不限制行数；达到容量后仅移除较早的输出。'**
  String get shellOutputLimitNote;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonSettingsSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存设置失败'**
  String get commonSettingsSaveFailed;

  /// No description provided for @shellClearOutput.
  ///
  /// In zh, this message translates to:
  /// **'清空输出'**
  String get shellClearOutput;

  /// No description provided for @shellAbortCurrentCommand.
  ///
  /// In zh, this message translates to:
  /// **'中止当前命令'**
  String get shellAbortCurrentCommand;

  /// No description provided for @shellSendCtrlC.
  ///
  /// In zh, this message translates to:
  /// **'发送 Ctrl+C'**
  String get shellSendCtrlC;

  /// No description provided for @shellEmptyPrompt.
  ///
  /// In zh, this message translates to:
  /// **'输入命令并按回车执行\n↑/↓ 浏览历史\n运行中可输入内容并回车发送；点击停止按钮中止\n常用: ls, ps, logcat, dumpsys, top, df'**
  String get shellEmptyPrompt;

  /// No description provided for @shellRunningHint.
  ///
  /// In zh, this message translates to:
  /// **'向当前 Shell 输入内容并回车发送'**
  String get shellRunningHint;

  /// No description provided for @shellCommandHint.
  ///
  /// In zh, this message translates to:
  /// **'输入命令 (如: ls -la /sdcard)'**
  String get shellCommandHint;

  /// No description provided for @shellInteractiveHint.
  ///
  /// In zh, this message translates to:
  /// **'交互式 Shell · 输入 exit 结束'**
  String get shellInteractiveHint;

  /// No description provided for @shellRunningSessionHint.
  ///
  /// In zh, this message translates to:
  /// **'会话运行中 · 输入发送给当前进程'**
  String get shellRunningSessionHint;

  /// No description provided for @shellCommandAborted.
  ///
  /// In zh, this message translates to:
  /// **'^C (已中止)'**
  String get shellCommandAborted;

  /// No description provided for @shellCommandError.
  ///
  /// In zh, this message translates to:
  /// **'错误: {error}'**
  String shellCommandError(Object error);

  /// No description provided for @shellSendInputFailed.
  ///
  /// In zh, this message translates to:
  /// **'发送输入失败: {error}'**
  String shellSendInputFailed(Object error);

  /// No description provided for @shellEarlierOutputOmitted.
  ///
  /// In zh, this message translates to:
  /// **'…较早的输出已省略…'**
  String get shellEarlierOutputOmitted;

  /// No description provided for @appsSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索应用名称或包名'**
  String get appsSearchHint;

  /// No description provided for @appsFilterUser.
  ///
  /// In zh, this message translates to:
  /// **'用户应用'**
  String get appsFilterUser;

  /// No description provided for @appsFilterSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统应用'**
  String get appsFilterSystem;

  /// No description provided for @appsFilterFrozen.
  ///
  /// In zh, this message translates to:
  /// **'已冻结'**
  String get appsFilterFrozen;

  /// No description provided for @appsFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get appsFilterAll;

  /// No description provided for @appsRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新应用列表'**
  String get appsRefresh;

  /// No description provided for @appsCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个应用'**
  String appsCount(int count);

  /// No description provided for @appsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有符合条件的应用'**
  String get appsEmpty;

  /// No description provided for @appsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取应用列表失败：{error}'**
  String appsLoadFailed(Object error);

  /// No description provided for @appsVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本 {version}'**
  String appsVersion(Object version);

  /// No description provided for @appsSize.
  ///
  /// In zh, this message translates to:
  /// **'大小 {size}'**
  String appsSize(Object size);

  /// No description provided for @appsPath.
  ///
  /// In zh, this message translates to:
  /// **'路径 {path}'**
  String appsPath(Object path);

  /// No description provided for @appsFrozenBadge.
  ///
  /// In zh, this message translates to:
  /// **'已冻结'**
  String get appsFrozenBadge;

  /// No description provided for @appsDisabledBadge.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get appsDisabledBadge;

  /// No description provided for @appsSuspendedBadge.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get appsSuspendedBadge;

  /// No description provided for @appsAmFrozenBadge.
  ///
  /// In zh, this message translates to:
  /// **'AM 冻结'**
  String get appsAmFrozenBadge;

  /// No description provided for @appsFreezeMethod.
  ///
  /// In zh, this message translates to:
  /// **'冻结方式'**
  String get appsFreezeMethod;

  /// No description provided for @appsFreezeTitle.
  ///
  /// In zh, this message translates to:
  /// **'冻结应用'**
  String get appsFreezeTitle;

  /// No description provided for @appsUnfreezeTitle.
  ///
  /// In zh, this message translates to:
  /// **'解冻应用'**
  String get appsUnfreezeTitle;

  /// No description provided for @appsFreezePrompt.
  ///
  /// In zh, this message translates to:
  /// **'选择冻结 {name} 的方式'**
  String appsFreezePrompt(Object name);

  /// No description provided for @appsUnfreezePrompt.
  ///
  /// In zh, this message translates to:
  /// **'选择解除 {name} 冻结的方式'**
  String appsUnfreezePrompt(Object name);

  /// No description provided for @appsFreezeMethodDisableUser.
  ///
  /// In zh, this message translates to:
  /// **'停用应用'**
  String get appsFreezeMethodDisableUser;

  /// No description provided for @appsFreezeMethodDisableUserDescription.
  ///
  /// In zh, this message translates to:
  /// **'pm disable-user：用户停用，应用无法启动。适配范围最广。'**
  String get appsFreezeMethodDisableUserDescription;

  /// No description provided for @appsFreezeMethodSuspend.
  ///
  /// In zh, this message translates to:
  /// **'暂停应用'**
  String get appsFreezeMethodSuspend;

  /// No description provided for @appsFreezeMethodSuspendDescription.
  ///
  /// In zh, this message translates to:
  /// **'pm suspend：暂停并隐藏应用，数据保留，可随时恢复。'**
  String get appsFreezeMethodSuspendDescription;

  /// No description provided for @appsFreezeMethodAmFreeze.
  ///
  /// In zh, this message translates to:
  /// **'AM 冻结'**
  String get appsFreezeMethodAmFreeze;

  /// No description provided for @appsFreezeMethodAmFreezeDescription.
  ///
  /// In zh, this message translates to:
  /// **'am freeze：由 ActivityManager 冻结进程，需要 Android 15+。'**
  String get appsFreezeMethodAmFreezeDescription;

  /// No description provided for @appsExportAction.
  ///
  /// In zh, this message translates to:
  /// **'导出 APK'**
  String get appsExportAction;

  /// No description provided for @appsExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出应用'**
  String get appsExportTitle;

  /// No description provided for @appsExportPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入要将 {name} 拉取到的目标目录'**
  String appsExportPrompt(Object name);

  /// No description provided for @appsExportDirectory.
  ///
  /// In zh, this message translates to:
  /// **'目标目录'**
  String get appsExportDirectory;

  /// No description provided for @appsExportSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已导出到 {path}'**
  String appsExportSucceeded(Object path);

  /// No description provided for @appsUninstallAction.
  ///
  /// In zh, this message translates to:
  /// **'卸载'**
  String get appsUninstallAction;

  /// No description provided for @appsUninstallTitle.
  ///
  /// In zh, this message translates to:
  /// **'卸载应用'**
  String get appsUninstallTitle;

  /// No description provided for @appsUninstallConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定卸载 {name}（{packageName}）吗？'**
  String appsUninstallConfirm(Object name, Object packageName);

  /// No description provided for @appsUninstallSystemTitle.
  ///
  /// In zh, this message translates to:
  /// **'卸载系统应用'**
  String get appsUninstallSystemTitle;

  /// No description provided for @appsUninstallSystemConfirm.
  ///
  /// In zh, this message translates to:
  /// **'{name}（{packageName}）是系统应用。卸载后可能影响相关功能，且通常很难恢复。确定继续吗？'**
  String appsUninstallSystemConfirm(Object name, Object packageName);

  /// No description provided for @appsUninstallCoreTitle.
  ///
  /// In zh, this message translates to:
  /// **'卸载核心系统应用'**
  String get appsUninstallCoreTitle;

  /// No description provided for @appsUninstallCoreConfirm.
  ///
  /// In zh, this message translates to:
  /// **'{name}（{packageName}）是核心系统组件。卸载后可能导致无法开机、没有桌面、无法拨号或无法打开设置，且很难恢复。确定仍要卸载吗？'**
  String appsUninstallCoreConfirm(Object name, Object packageName);

  /// No description provided for @appsUninstallConfirmAction.
  ///
  /// In zh, this message translates to:
  /// **'仍然卸载'**
  String get appsUninstallConfirmAction;

  /// No description provided for @appsUninstallSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已卸载 {name}'**
  String appsUninstallSucceeded(Object name);

  /// No description provided for @appsFreezeSystemTitle.
  ///
  /// In zh, this message translates to:
  /// **'冻结系统应用'**
  String get appsFreezeSystemTitle;

  /// No description provided for @appsFreezeSystemConfirm.
  ///
  /// In zh, this message translates to:
  /// **'{name}（{packageName}）是系统应用。冻结后可能影响相关功能，确定继续吗？'**
  String appsFreezeSystemConfirm(Object name, Object packageName);

  /// No description provided for @appsFreezeCoreTitle.
  ///
  /// In zh, this message translates to:
  /// **'冻结核心系统应用'**
  String get appsFreezeCoreTitle;

  /// No description provided for @appsFreezeCoreConfirm.
  ///
  /// In zh, this message translates to:
  /// **'{name}（{packageName}）是核心系统组件。冻结后可能导致无法开机、没有桌面、无法拨号或无法打开设置。确定仍要冻结吗？'**
  String appsFreezeCoreConfirm(Object name, Object packageName);

  /// No description provided for @appsFreezeConfirmAction.
  ///
  /// In zh, this message translates to:
  /// **'仍然冻结'**
  String get appsFreezeConfirmAction;

  /// No description provided for @appsFreezeAction.
  ///
  /// In zh, this message translates to:
  /// **'冻结'**
  String get appsFreezeAction;

  /// No description provided for @appsUnfreezeAction.
  ///
  /// In zh, this message translates to:
  /// **'解冻'**
  String get appsUnfreezeAction;

  /// No description provided for @appsFreezeSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已冻结 {name}'**
  String appsFreezeSucceeded(Object name);

  /// No description provided for @appsUnfreezeSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已解冻 {name}'**
  String appsUnfreezeSucceeded(Object name);

  /// No description provided for @appsActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get appsActionFailed;

  /// No description provided for @appsSelect.
  ///
  /// In zh, this message translates to:
  /// **'多选'**
  String get appsSelect;

  /// No description provided for @appsSelectDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get appsSelectDone;

  /// No description provided for @appsSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get appsSelectAll;

  /// No description provided for @appsSelectClear.
  ///
  /// In zh, this message translates to:
  /// **'取消选择'**
  String get appsSelectClear;

  /// No description provided for @appsSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 个'**
  String appsSelectedCount(int count);

  /// No description provided for @appsBatchUninstallConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定卸载选中的 {count} 个应用吗？'**
  String appsBatchUninstallConfirm(int count);

  /// No description provided for @appsBatchUninstallSystemConfirm.
  ///
  /// In zh, this message translates to:
  /// **'选中的 {count} 个应用包含系统应用（{names}）。卸载后可能影响相关功能，且通常很难恢复。确定继续吗？'**
  String appsBatchUninstallSystemConfirm(int count, Object names);

  /// No description provided for @appsBatchUninstallCoreConfirm.
  ///
  /// In zh, this message translates to:
  /// **'选中的 {count} 个应用包含核心系统组件（{names}）。卸载后可能导致无法开机、没有桌面、无法拨号或无法打开设置，且很难恢复。确定仍要卸载吗？'**
  String appsBatchUninstallCoreConfirm(int count, Object names);

  /// No description provided for @appsBatchFreezeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定冻结选中的 {count} 个应用吗？'**
  String appsBatchFreezeConfirm(int count);

  /// No description provided for @appsBatchFreezeSystemConfirm.
  ///
  /// In zh, this message translates to:
  /// **'选中的 {count} 个应用包含系统应用（{names}）。冻结后可能影响相关功能，确定继续吗？'**
  String appsBatchFreezeSystemConfirm(int count, Object names);

  /// No description provided for @appsBatchFreezeCoreConfirm.
  ///
  /// In zh, this message translates to:
  /// **'选中的 {count} 个应用包含核心系统组件（{names}）。冻结后可能导致无法开机、没有桌面、无法拨号或无法打开设置。确定仍要冻结吗？'**
  String appsBatchFreezeCoreConfirm(int count, Object names);

  /// No description provided for @appsBatchExportPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入要将选中的 {count} 个应用拉取到的目标目录'**
  String appsBatchExportPrompt(int count);

  /// No description provided for @appsBatchUninstallSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已卸载 {count} 个应用'**
  String appsBatchUninstallSucceeded(int count);

  /// No description provided for @appsBatchFreezeSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已冻结 {count} 个应用'**
  String appsBatchFreezeSucceeded(int count);

  /// No description provided for @appsBatchExportSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已导出 {count} 个应用到 {path}'**
  String appsBatchExportSucceeded(int count, Object path);

  /// No description provided for @appsTaskExport.
  ///
  /// In zh, this message translates to:
  /// **'正在导出'**
  String get appsTaskExport;

  /// No description provided for @appsTaskUninstall.
  ///
  /// In zh, this message translates to:
  /// **'正在卸载'**
  String get appsTaskUninstall;

  /// No description provided for @appsTaskFreeze.
  ///
  /// In zh, this message translates to:
  /// **'正在冻结'**
  String get appsTaskFreeze;

  /// No description provided for @appsTaskUnfreeze.
  ///
  /// In zh, this message translates to:
  /// **'正在解冻'**
  String get appsTaskUnfreeze;

  /// No description provided for @appsTaskProgress.
  ///
  /// In zh, this message translates to:
  /// **'{action} {name}（{completed}/{total}，{percent}%）'**
  String appsTaskProgress(
    Object action,
    Object name,
    int completed,
    int total,
    int percent,
  );

  /// No description provided for @appsExportMeasuring.
  ///
  /// In zh, this message translates to:
  /// **'正在计算大小…'**
  String get appsExportMeasuring;

  /// No description provided for @appsExportBytes.
  ///
  /// In zh, this message translates to:
  /// **'{done} / {total}'**
  String appsExportBytes(Object done, Object total);

  /// No description provided for @appsExportPercent.
  ///
  /// In zh, this message translates to:
  /// **'{percent}%'**
  String appsExportPercent(int percent);

  /// No description provided for @appsCancelTask.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get appsCancelTask;

  /// No description provided for @appsTaskCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get appsTaskCancelled;

  /// No description provided for @appsTaskCancelledDone.
  ///
  /// In zh, this message translates to:
  /// **'已取消，已完成 {count} 个'**
  String appsTaskCancelledDone(int count);

  /// No description provided for @appsBatchPartial.
  ///
  /// In zh, this message translates to:
  /// **'成功 {succeeded} 个，失败 {failed} 个'**
  String appsBatchPartial(int succeeded, int failed);
}

class _FireAdbLocalizationsDelegate
    extends LocalizationsDelegate<FireAdbLocalizations> {
  const _FireAdbLocalizationsDelegate();

  @override
  Future<FireAdbLocalizations> load(Locale locale) {
    return SynchronousFuture<FireAdbLocalizations>(
      lookupFireAdbLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_FireAdbLocalizationsDelegate old) => false;
}

FireAdbLocalizations lookupFireAdbLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return FireAdbLocalizationsEn();
    case 'zh':
      return FireAdbLocalizationsZh();
  }

  throw FlutterError(
    'FireAdbLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
