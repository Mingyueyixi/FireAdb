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

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsPreferSdkAdb.
  ///
  /// In zh, this message translates to:
  /// **'优先使用 SDK 的 adb server'**
  String get settingsPreferSdkAdb;

  /// No description provided for @settingsChooseLanguage.
  ///
  /// In zh, this message translates to:
  /// **'选择语言'**
  String get settingsChooseLanguage;

  /// No description provided for @settingsAdbServerPort.
  ///
  /// In zh, this message translates to:
  /// **'FireAdb server 端口'**
  String get settingsAdbServerPort;

  /// No description provided for @settingsAdbServerPortHelp.
  ///
  /// In zh, this message translates to:
  /// **'默认 5037。应用后，FireAdb 在新端口重新启动自己的 server，本应用的设备列表连到这里。其他 adb 客户端仍去连接 5037 上的 adb server；5037 上没有服务时，adb 会自己在 5037 起一个。'**
  String get settingsAdbServerPortHelp;

  /// No description provided for @settingsApply.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get settingsApply;

  /// No description provided for @settingsAdbServerPortInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 1 到 65535 之间的端口'**
  String get settingsAdbServerPortInvalid;

  /// No description provided for @settingsPreferSdkAdbHelp.
  ///
  /// In zh, this message translates to:
  /// **'在电脑上找到 adb 后，由它在上面的端口启动，不再由本进程监听。'**
  String get settingsPreferSdkAdbHelp;

  /// No description provided for @settingsSdkAdbPath.
  ///
  /// In zh, this message translates to:
  /// **'已找到 {path}'**
  String settingsSdkAdbPath(Object path);

  /// No description provided for @settingsSdkAdbMissing.
  ///
  /// In zh, this message translates to:
  /// **'未找到 adb，仍使用 FireAdb 的 server。'**
  String get settingsSdkAdbMissing;

  /// No description provided for @settingsSdkAdbStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'启动 SDK 的 adb server 失败：{error}'**
  String settingsSdkAdbStartFailed(Object error);

  /// No description provided for @settingsLanguageSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存语言设置失败：{error}'**
  String settingsLanguageSaveFailed(Object error);

  /// No description provided for @settingsAutoRefreshMdns.
  ///
  /// In zh, this message translates to:
  /// **'自动刷新 mDNS'**
  String get settingsAutoRefreshMdns;

  /// No description provided for @settingsAutoRefreshDevices.
  ///
  /// In zh, this message translates to:
  /// **'自动刷新设备列表'**
  String get settingsAutoRefreshDevices;

  /// No description provided for @settingsAutoRefreshHelp.
  ///
  /// In zh, this message translates to:
  /// **'勾选后每 {seconds} 秒刷新一次'**
  String settingsAutoRefreshHelp(int seconds);

  /// No description provided for @settingsAutoRefreshInterval.
  ///
  /// In zh, this message translates to:
  /// **'刷新间隔（秒）'**
  String get settingsAutoRefreshInterval;

  /// No description provided for @settingsAutoRefreshIntervalInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 1 到 3600 之间的整数'**
  String get settingsAutoRefreshIntervalInvalid;

  /// No description provided for @settingsRefreshInBackground.
  ///
  /// In zh, this message translates to:
  /// **'后台刷新'**
  String get settingsRefreshInBackground;

  /// No description provided for @settingsRefreshInBackgroundHelp.
  ///
  /// In zh, this message translates to:
  /// **'关闭时，连接页不在最前面或应用进入后台，自动刷新会停下来。'**
  String get settingsRefreshInBackgroundHelp;

  /// No description provided for @settingsLogDirectory.
  ///
  /// In zh, this message translates to:
  /// **'日志目录'**
  String get settingsLogDirectory;

  /// No description provided for @settingsOpenLogDirectory.
  ///
  /// In zh, this message translates to:
  /// **'在文件管理器中打开'**
  String get settingsOpenLogDirectory;

  /// No description provided for @settingsLogDirectoryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'日志目录还不可用'**
  String get settingsLogDirectoryUnavailable;

  /// No description provided for @settingsOpenLogDirectoryFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开日志目录：{error}'**
  String settingsOpenLogDirectoryFailed(Object error);

  /// No description provided for @settingsLogBuffer.
  ///
  /// In zh, this message translates to:
  /// **'日志显示缓冲区（KB）'**
  String get settingsLogBuffer;

  /// No description provided for @settingsLogBufferHelp.
  ///
  /// In zh, this message translates to:
  /// **'日志页在内存中保留这些内容，默认 256 KB。'**
  String get settingsLogBufferHelp;

  /// No description provided for @settingsLogBufferInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 16 到 8192 之间的整数'**
  String get settingsLogBufferInvalid;

  /// No description provided for @settingsLogRetention.
  ///
  /// In zh, this message translates to:
  /// **'日志保存天数'**
  String get settingsLogRetention;

  /// No description provided for @settingsLogRetentionHelp.
  ///
  /// In zh, this message translates to:
  /// **'启动时删除早于这个天数的日志文件。默认 7 天。'**
  String get settingsLogRetentionHelp;

  /// No description provided for @settingsLogRetentionInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 1 到 365 之间的整数'**
  String get settingsLogRetentionInvalid;

  /// No description provided for @settingsLogDeleteAll.
  ///
  /// In zh, this message translates to:
  /// **'一键清理'**
  String get settingsLogDeleteAll;

  /// No description provided for @settingsLogDeleteAllTitle.
  ///
  /// In zh, this message translates to:
  /// **'清理日志文件'**
  String get settingsLogDeleteAllTitle;

  /// No description provided for @settingsLogDeleteAllMessage.
  ///
  /// In zh, this message translates to:
  /// **'删除日志目录中的全部日志文件？正在写入的文件会重新开始，页面上已显示的内容保留。'**
  String get settingsLogDeleteAllMessage;

  /// No description provided for @settingsLogDeleteAllFailed.
  ///
  /// In zh, this message translates to:
  /// **'清理日志文件失败：{error}'**
  String settingsLogDeleteAllFailed(Object error);

  /// No description provided for @homeAutoRefresh.
  ///
  /// In zh, this message translates to:
  /// **'自动刷新'**
  String get homeAutoRefresh;

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
  /// **'在手机上打开系统「设置 → 开发者选项 → 无线调试 → 使用配对码配对设备」，并保持该页面打开。在安卓端连接本机时，可能无法停留在数字配对码页面，请使用悬浮窗或分屏，避免配对服务关闭导致无法连接。\n在本页点「扫描」，对出现的配对服务点「配对」并输入手机上的配对码，再点本页列出的无线调试端口连接。已配对过的设备只需在本页点「扫描」后连接。'**
  String get homeMdnsHelp;

  /// No description provided for @homePairingCodeGuideTitle.
  ///
  /// In zh, this message translates to:
  /// **'配对码配对：'**
  String get homePairingCodeGuideTitle;

  /// No description provided for @homeQrPairingGuideTitle.
  ///
  /// In zh, this message translates to:
  /// **'二维码配对：'**
  String get homeQrPairingGuideTitle;

  /// No description provided for @homeQrPairingGuide.
  ///
  /// In zh, this message translates to:
  /// **'在本页点「二维码配对」。手机打开系统「设置 → 开发者选项 → 无线调试 → 使用二维码配对设备」，扫描本页弹出的二维码。本应用会自动完成配对并连接。'**
  String get homeQrPairingGuide;

  /// No description provided for @homeScanFailed.
  ///
  /// In zh, this message translates to:
  /// **'扫描失败：{error}'**
  String homeScanFailed(Object error);

  /// No description provided for @homeNoDevicesFound.
  ///
  /// In zh, this message translates to:
  /// **'未扫描到当前设备，请确认当前设备'**
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

  /// No description provided for @homePair.
  ///
  /// In zh, this message translates to:
  /// **'配对'**
  String get homePair;

  /// No description provided for @homePairingTitle.
  ///
  /// In zh, this message translates to:
  /// **'无线配对'**
  String get homePairingTitle;

  /// No description provided for @homePairingCodeHelp.
  ///
  /// In zh, this message translates to:
  /// **'输入无线调试页面上的配对码。'**
  String get homePairingCodeHelp;

  /// No description provided for @homePairingSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'配对成功'**
  String get homePairingSucceeded;

  /// No description provided for @homePairingSucceededHint.
  ///
  /// In zh, this message translates to:
  /// **'请点对应的无线调试端口进行连接。'**
  String get homePairingSucceededHint;

  /// No description provided for @homeQrPair.
  ///
  /// In zh, this message translates to:
  /// **'二维码配对'**
  String get homeQrPair;

  /// No description provided for @homeQrPairingTitle.
  ///
  /// In zh, this message translates to:
  /// **'二维码配对'**
  String get homeQrPairingTitle;

  /// No description provided for @homeQrPairingPrinciple.
  ///
  /// In zh, this message translates to:
  /// **'二维码里是服务名和配对密码。手机扫码后会用这个名字发布配对服务，本应用找到同名服务后用该密码完成配对，再连接无线调试端口。'**
  String get homeQrPairingPrinciple;

  /// No description provided for @homeQrPairingHelp.
  ///
  /// In zh, this message translates to:
  /// **'在手机上打开「设置 → 开发者选项 → 无线调试 → 使用二维码配对设备」，扫描此二维码。手机与本应用需在同一 Wi-Fi。'**
  String get homeQrPairingHelp;

  /// No description provided for @homeQrPairingWaiting.
  ///
  /// In zh, this message translates to:
  /// **'等待手机扫描…'**
  String get homeQrPairingWaiting;

  /// No description provided for @homeQrPairingPairing.
  ///
  /// In zh, this message translates to:
  /// **'正在配对…'**
  String get homeQrPairingPairing;

  /// No description provided for @homeQrPairingConnecting.
  ///
  /// In zh, this message translates to:
  /// **'配对成功，正在连接…'**
  String get homeQrPairingConnecting;

  /// No description provided for @homeQrPairingTimeout.
  ///
  /// In zh, this message translates to:
  /// **'没有等到手机扫描。请确认无线调试已打开，然后重试。'**
  String get homeQrPairingTimeout;

  /// No description provided for @homeQrPairingFailed.
  ///
  /// In zh, this message translates to:
  /// **'二维码配对失败：{error}'**
  String homeQrPairingFailed(Object error);

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

  /// No description provided for @homeUsbDevicesReadError.
  ///
  /// In zh, this message translates to:
  /// **'无法读取 USB 设备：{error}'**
  String homeUsbDevicesReadError(Object error);

  /// No description provided for @homeNoAdbDevices.
  ///
  /// In zh, this message translates to:
  /// **'ADB Server 当前没有发现设备。'**
  String get homeNoAdbDevices;

  /// No description provided for @homeAdbServerUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'本机 ADB Server 不可用，设备列表无法刷新。'**
  String get homeAdbServerUnavailable;

  /// No description provided for @homeAdbServerNotRunning.
  ///
  /// In zh, this message translates to:
  /// **'本机没有 ADB Server（127.0.0.1:{port}）。USB 设备会直接列出，网络设备请手动连接或扫描。'**
  String homeAdbServerNotRunning(Object port);

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
  /// **'浏览设备文件，支持删除、重命名、复制粘贴、编辑、搜索、改权限，以及导出和从电脑上传'**
  String get workspaceFilesDescription;

  /// No description provided for @workspaceScreenshotTitle.
  ///
  /// In zh, this message translates to:
  /// **'截图'**
  String get workspaceScreenshotTitle;

  /// No description provided for @workspaceScreenshotDescription.
  ///
  /// In zh, this message translates to:
  /// **'调用 screencap -p 截取屏幕，并把 PNG 保存到应用目录'**
  String get workspaceScreenshotDescription;

  /// No description provided for @workspaceScreenrecordTitle.
  ///
  /// In zh, this message translates to:
  /// **'录屏'**
  String get workspaceScreenrecordTitle;

  /// No description provided for @workspaceScreenrecordDescription.
  ///
  /// In zh, this message translates to:
  /// **'录制屏幕并保存到应用目录，可选用系统或内置录屏'**
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

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

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
  /// **'选择要将 {name} 拉取到的目录'**
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
  /// **'选择要将选中的 {count} 个应用拉取到的目录'**
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

  /// No description provided for @filesPath.
  ///
  /// In zh, this message translates to:
  /// **'设备路径'**
  String get filesPath;

  /// No description provided for @filesUp.
  ///
  /// In zh, this message translates to:
  /// **'上级目录'**
  String get filesUp;

  /// No description provided for @filesRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get filesRefresh;

  /// No description provided for @filesUpload.
  ///
  /// In zh, this message translates to:
  /// **'上传'**
  String get filesUpload;

  /// No description provided for @filesCreate.
  ///
  /// In zh, this message translates to:
  /// **'新建'**
  String get filesCreate;

  /// No description provided for @filesFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get filesFile;

  /// No description provided for @filesFolder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹'**
  String get filesFolder;

  /// No description provided for @filesLink.
  ///
  /// In zh, this message translates to:
  /// **'链接'**
  String get filesLink;

  /// No description provided for @filesName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get filesName;

  /// No description provided for @filesSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get filesSearch;

  /// No description provided for @filesSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'在当前目录中按名称搜索'**
  String get filesSearchHint;

  /// No description provided for @filesClearSearch.
  ///
  /// In zh, this message translates to:
  /// **'清除搜索'**
  String get filesClearSearch;

  /// No description provided for @filesSearching.
  ///
  /// In zh, this message translates to:
  /// **'正在显示“{keyword}”的搜索结果'**
  String filesSearching(Object keyword);

  /// No description provided for @filesSearchEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的文件'**
  String get filesSearchEmpty;

  /// No description provided for @filesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这个目录是空的'**
  String get filesEmpty;

  /// No description provided for @filesSelect.
  ///
  /// In zh, this message translates to:
  /// **'多选'**
  String get filesSelect;

  /// No description provided for @filesClearSelection.
  ///
  /// In zh, this message translates to:
  /// **'取消多选'**
  String get filesClearSelection;

  /// No description provided for @filesSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get filesSelectAll;

  /// No description provided for @filesOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get filesOpen;

  /// No description provided for @filesDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get filesDelete;

  /// No description provided for @filesDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'删除 {name}？此操作不可恢复'**
  String filesDeleteConfirm(Object name);

  /// No description provided for @filesBatchDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'删除选中的 {count} 项？此操作不可恢复'**
  String filesBatchDeleteConfirm(int count);

  /// No description provided for @filesDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {count} 项'**
  String filesDeleted(int count);

  /// No description provided for @filesRename.
  ///
  /// In zh, this message translates to:
  /// **'重命名'**
  String get filesRename;

  /// No description provided for @filesRenamed.
  ///
  /// In zh, this message translates to:
  /// **'已重命名'**
  String get filesRenamed;

  /// No description provided for @filesInvalidName.
  ///
  /// In zh, this message translates to:
  /// **'名称不能为空，也不能包含 /'**
  String get filesInvalidName;

  /// No description provided for @filesCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get filesCopy;

  /// No description provided for @filesCut.
  ///
  /// In zh, this message translates to:
  /// **'剪切'**
  String get filesCut;

  /// No description provided for @filesPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get filesPaste;

  /// No description provided for @filesPasteIntoSelf.
  ///
  /// In zh, this message translates to:
  /// **'不能把目录粘贴到它自己里面'**
  String get filesPasteIntoSelf;

  /// No description provided for @filesPasted.
  ///
  /// In zh, this message translates to:
  /// **'已粘贴 {count} 项'**
  String filesPasted(int count);

  /// No description provided for @filesClipboardCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制 {count} 项，可粘贴到其他目录'**
  String filesClipboardCopied(int count);

  /// No description provided for @filesClipboardCut.
  ///
  /// In zh, this message translates to:
  /// **'已剪切 {count} 项，可粘贴到其他目录'**
  String filesClipboardCut(int count);

  /// No description provided for @filesEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get filesEdit;

  /// No description provided for @filesEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑 {name}'**
  String filesEditTitle(Object name);

  /// No description provided for @filesEditTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件超过 512 KB，不能在这里编辑'**
  String get filesEditTooLarge;

  /// No description provided for @filesEditBinary.
  ///
  /// In zh, this message translates to:
  /// **'这不是文本文件'**
  String get filesEditBinary;

  /// No description provided for @filesSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get filesSaved;

  /// No description provided for @filesPermission.
  ///
  /// In zh, this message translates to:
  /// **'权限'**
  String get filesPermission;

  /// No description provided for @filesPermissionHint.
  ///
  /// In zh, this message translates to:
  /// **'八进制权限，例如 644'**
  String get filesPermissionHint;

  /// No description provided for @filesInvalidPermission.
  ///
  /// In zh, this message translates to:
  /// **'请输入 3 到 4 位八进制权限'**
  String get filesInvalidPermission;

  /// No description provided for @filesPermissionUpdated.
  ///
  /// In zh, this message translates to:
  /// **'已修改权限'**
  String get filesPermissionUpdated;

  /// No description provided for @filesCreated.
  ///
  /// In zh, this message translates to:
  /// **'已创建 {name}'**
  String filesCreated(Object name);

  /// No description provided for @filesExport.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get filesExport;

  /// No description provided for @filesExportPrompt.
  ///
  /// In zh, this message translates to:
  /// **'选择要将 {name} 导出到的目录'**
  String filesExportPrompt(Object name);

  /// No description provided for @filesBatchExportPrompt.
  ///
  /// In zh, this message translates to:
  /// **'选择要将选中的 {count} 项导出到的目录'**
  String filesBatchExportPrompt(int count);

  /// No description provided for @filesExportSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已导出到 {path}'**
  String filesExportSucceeded(Object path);

  /// No description provided for @filesUploadSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已上传 {count} 个文件'**
  String filesUploadSucceeded(int count);

  /// No description provided for @filesOverwrite.
  ///
  /// In zh, this message translates to:
  /// **'目标目录已有同名文件，上传将覆盖：{names}'**
  String filesOverwrite(Object names);

  /// No description provided for @filesLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取目录失败：{error}'**
  String filesLoadFailed(Object error);

  /// No description provided for @filesActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get filesActionFailed;

  /// No description provided for @filesTaskDelete.
  ///
  /// In zh, this message translates to:
  /// **'正在删除'**
  String get filesTaskDelete;

  /// No description provided for @filesTaskRename.
  ///
  /// In zh, this message translates to:
  /// **'正在重命名'**
  String get filesTaskRename;

  /// No description provided for @filesTaskCopy.
  ///
  /// In zh, this message translates to:
  /// **'正在复制'**
  String get filesTaskCopy;

  /// No description provided for @filesTaskMove.
  ///
  /// In zh, this message translates to:
  /// **'正在移动'**
  String get filesTaskMove;

  /// No description provided for @filesTaskExport.
  ///
  /// In zh, this message translates to:
  /// **'正在导出'**
  String get filesTaskExport;

  /// No description provided for @filesTaskUpload.
  ///
  /// In zh, this message translates to:
  /// **'正在上传'**
  String get filesTaskUpload;

  /// No description provided for @filesTaskSave.
  ///
  /// In zh, this message translates to:
  /// **'正在保存'**
  String get filesTaskSave;

  /// No description provided for @filesLocationsStorage.
  ///
  /// In zh, this message translates to:
  /// **'内部存储'**
  String get filesLocationsStorage;

  /// No description provided for @filesLocationsTemp.
  ///
  /// In zh, this message translates to:
  /// **'临时目录'**
  String get filesLocationsTemp;

  /// No description provided for @filesLocationsRoot.
  ///
  /// In zh, this message translates to:
  /// **'根目录'**
  String get filesLocationsRoot;

  /// No description provided for @captureDirectoryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'找不到应用目录，无法保存文件'**
  String get captureDirectoryUnavailable;

  /// No description provided for @captureSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存到 {path}'**
  String captureSaved(Object path);

  /// No description provided for @captureSaveLocation.
  ///
  /// In zh, this message translates to:
  /// **'保存位置'**
  String get captureSaveLocation;

  /// No description provided for @captureOpenFolder.
  ///
  /// In zh, this message translates to:
  /// **'打开应用目录'**
  String get captureOpenFolder;

  /// No description provided for @captureOpenFile.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get captureOpenFile;

  /// No description provided for @captureOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开：{error}'**
  String captureOpenFailed(Object error);

  /// No description provided for @captureRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get captureRefresh;

  /// No description provided for @captureDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get captureDelete;

  /// No description provided for @captureDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'从应用目录删除 {name}？'**
  String captureDeleteConfirm(Object name);

  /// No description provided for @captureDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {name}'**
  String captureDeleted(Object name);

  /// No description provided for @captureActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get captureActionFailed;

  /// No description provided for @captureDeviceOutput.
  ///
  /// In zh, this message translates to:
  /// **'设备输出：{output}'**
  String captureDeviceOutput(Object output);

  /// No description provided for @captureFailedWithRemote.
  ///
  /// In zh, this message translates to:
  /// **'{error}。设备上的临时文件仍在 {path}'**
  String captureFailedWithRemote(Object error, Object path);

  /// No description provided for @captureEmptyScreenshots.
  ///
  /// In zh, this message translates to:
  /// **'应用目录里还没有截图'**
  String get captureEmptyScreenshots;

  /// No description provided for @captureEmptyRecordings.
  ///
  /// In zh, this message translates to:
  /// **'应用目录里还没有录像'**
  String get captureEmptyRecordings;

  /// No description provided for @screenshotCapture.
  ///
  /// In zh, this message translates to:
  /// **'截取屏幕'**
  String get screenshotCapture;

  /// No description provided for @screenshotCapturing.
  ///
  /// In zh, this message translates to:
  /// **'正在截取屏幕…'**
  String get screenshotCapturing;

  /// No description provided for @screenshotInvalid.
  ///
  /// In zh, this message translates to:
  /// **'设备没有返回有效的 PNG'**
  String get screenshotInvalid;

  /// No description provided for @screenrecordStart.
  ///
  /// In zh, this message translates to:
  /// **'开始录屏'**
  String get screenrecordStart;

  /// No description provided for @screenrecordStop.
  ///
  /// In zh, this message translates to:
  /// **'停止并保存'**
  String get screenrecordStop;

  /// No description provided for @screenrecordSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存到应用目录…'**
  String get screenrecordSaving;

  /// No description provided for @screenrecordRecording.
  ///
  /// In zh, this message translates to:
  /// **'正在录制'**
  String get screenrecordRecording;

  /// No description provided for @screenrecordTimeLimit.
  ///
  /// In zh, this message translates to:
  /// **'时长上限'**
  String get screenrecordTimeLimit;

  /// No description provided for @screenrecordLimit30.
  ///
  /// In zh, this message translates to:
  /// **'30 秒'**
  String get screenrecordLimit30;

  /// No description provided for @screenrecordLimit60.
  ///
  /// In zh, this message translates to:
  /// **'1 分钟'**
  String get screenrecordLimit60;

  /// No description provided for @screenrecordLimit180.
  ///
  /// In zh, this message translates to:
  /// **'3 分钟'**
  String get screenrecordLimit180;

  /// No description provided for @screenrecordLimitNone.
  ///
  /// In zh, this message translates to:
  /// **'不限时'**
  String get screenrecordLimitNone;

  /// No description provided for @screenrecordTimeLimitNote.
  ///
  /// In zh, this message translates to:
  /// **'Android 13 及更早版本最长 3 分钟，超过会被系统拒绝。'**
  String get screenrecordTimeLimitNote;

  /// No description provided for @screenrecordTimeLimitUnlimited.
  ///
  /// In zh, this message translates to:
  /// **'这台设备不限制最长时长，可以选择不限时。'**
  String get screenrecordTimeLimitUnlimited;

  /// No description provided for @screenrecordHint.
  ///
  /// In zh, this message translates to:
  /// **'停止后保存到应用目录，并删除设备上的临时视频。'**
  String get screenrecordHint;

  /// No description provided for @screenrecordMethod.
  ///
  /// In zh, this message translates to:
  /// **'录制方式'**
  String get screenrecordMethod;

  /// No description provided for @screenrecordMethodSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统录屏'**
  String get screenrecordMethodSystem;

  /// No description provided for @screenrecordMethodSystemSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'调用设备自带的 screenrecord'**
  String get screenrecordMethodSystemSubtitle;

  /// No description provided for @screenrecordMethodBuiltin.
  ///
  /// In zh, this message translates to:
  /// **'内置录屏'**
  String get screenrecordMethodBuiltin;

  /// No description provided for @screenrecordMethodBuiltinSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'用辅助服务编码，画面直接送进编码器。'**
  String get screenrecordMethodBuiltinSubtitle;

  /// No description provided for @screenrecordMethodScrcpy.
  ///
  /// In zh, this message translates to:
  /// **'投屏录屏'**
  String get screenrecordMethodScrcpy;

  /// No description provided for @screenrecordMethodScrcpySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'即将支持。同一条连接以后用于画面预览和远程操作。'**
  String get screenrecordMethodScrcpySubtitle;

  /// No description provided for @screenrecordShellCopyFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法准备临时目录里的录屏程序'**
  String get screenrecordShellCopyFailed;

  /// No description provided for @screenrecordShellUnsafe.
  ///
  /// In zh, this message translates to:
  /// **'临时目录里的录屏程序仍会被系统策略接管，已取消执行，文件仍留在原地'**
  String get screenrecordShellUnsafe;

  /// No description provided for @screenrecordTimeLimitBuiltin.
  ///
  /// In zh, this message translates to:
  /// **'内置录屏不限制最长时长，可以选择不限时。'**
  String get screenrecordTimeLimitBuiltin;

  /// No description provided for @screenrecordNoWritableDir.
  ///
  /// In zh, this message translates to:
  /// **'shell 无法以读写方式创建录像文件'**
  String get screenrecordNoWritableDir;

  /// No description provided for @screenrecordMissing.
  ///
  /// In zh, this message translates to:
  /// **'设备上没有生成录像文件'**
  String get screenrecordMissing;

  /// No description provided for @screenrecordInvalid.
  ///
  /// In zh, this message translates to:
  /// **'录像文件无效，仍留在设备上：{path}'**
  String screenrecordInvalid(Object path);

  /// No description provided for @screenrecordTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'录像有 {size}，超过可保存的大小，仍留在设备上：{path}'**
  String screenrecordTooLarge(Object size, Object path);

  /// No description provided for @storageAccessTitle.
  ///
  /// In zh, this message translates to:
  /// **'需要文件访问权限'**
  String get storageAccessTitle;

  /// No description provided for @storageAccessMessage.
  ///
  /// In zh, this message translates to:
  /// **'浏览和保存手机上的目录需要授予「所有文件访问权限」。'**
  String get storageAccessMessage;

  /// No description provided for @storageAccessGrant.
  ///
  /// In zh, this message translates to:
  /// **'去授权'**
  String get storageAccessGrant;

  /// No description provided for @localPickerChooseFolder.
  ///
  /// In zh, this message translates to:
  /// **'选择文件夹'**
  String get localPickerChooseFolder;

  /// No description provided for @localPickerChooseFiles.
  ///
  /// In zh, this message translates to:
  /// **'选择文件'**
  String get localPickerChooseFiles;

  /// No description provided for @localPickerUseFolder.
  ///
  /// In zh, this message translates to:
  /// **'选择此文件夹'**
  String get localPickerUseFolder;

  /// No description provided for @localPickerUseFiles.
  ///
  /// In zh, this message translates to:
  /// **'选择（{count}）'**
  String localPickerUseFiles(int count);

  /// No description provided for @localPickerStorage.
  ///
  /// In zh, this message translates to:
  /// **'存储设备'**
  String get localPickerStorage;

  /// No description provided for @localPickerInternalStorage.
  ///
  /// In zh, this message translates to:
  /// **'内部存储'**
  String get localPickerInternalStorage;

  /// No description provided for @localPickerEmpty.
  ///
  /// In zh, this message translates to:
  /// **'此目录是空的'**
  String get localPickerEmpty;

  /// No description provided for @localPickerUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取此目录'**
  String get localPickerUnreadable;

  /// No description provided for @localPickerNewFolder.
  ///
  /// In zh, this message translates to:
  /// **'新建文件夹'**
  String get localPickerNewFolder;

  /// No description provided for @localPickerInvalidName.
  ///
  /// In zh, this message translates to:
  /// **'名称不能包含 / 或 \\'**
  String get localPickerInvalidName;

  /// No description provided for @localPickerUp.
  ///
  /// In zh, this message translates to:
  /// **'上级目录'**
  String get localPickerUp;

  /// No description provided for @localPickerGo.
  ///
  /// In zh, this message translates to:
  /// **'前往'**
  String get localPickerGo;

  /// No description provided for @navConnection.
  ///
  /// In zh, this message translates to:
  /// **'连接'**
  String get navConnection;

  /// No description provided for @navLogs.
  ///
  /// In zh, this message translates to:
  /// **'日志'**
  String get navLogs;

  /// No description provided for @navAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get navAbout;

  /// No description provided for @logClear.
  ///
  /// In zh, this message translates to:
  /// **'清理'**
  String get logClear;

  /// No description provided for @logClearTitle.
  ///
  /// In zh, this message translates to:
  /// **'清理日志'**
  String get logClearTitle;

  /// No description provided for @logClearMessage.
  ///
  /// In zh, this message translates to:
  /// **'只清除当前显示的内容？日志文件仍会保留。'**
  String get logClearMessage;

  /// No description provided for @logEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有日志'**
  String get logEmpty;

  /// No description provided for @logRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get logRefresh;

  /// No description provided for @logTruncated.
  ///
  /// In zh, this message translates to:
  /// **'较早的日志未在此显示，仅保留末尾。'**
  String get logTruncated;

  /// No description provided for @logClearFailed.
  ///
  /// In zh, this message translates to:
  /// **'清理日志失败：{error}'**
  String logClearFailed(Object error);

  /// No description provided for @logReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取日志失败：{error}'**
  String logReadFailed(Object error);

  /// No description provided for @aboutVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本 {version}'**
  String aboutVersion(Object version);

  /// No description provided for @aboutBuild.
  ///
  /// In zh, this message translates to:
  /// **'构建号 {build}'**
  String aboutBuild(Object build);

  /// No description provided for @aboutDescription.
  ///
  /// In zh, this message translates to:
  /// **'跨平台 ADB 工具箱。协议自实现，不依赖系统 adb。'**
  String get aboutDescription;

  /// No description provided for @aboutVersionUnknown.
  ///
  /// In zh, this message translates to:
  /// **'版本信息还不可用'**
  String get aboutVersionUnknown;
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
