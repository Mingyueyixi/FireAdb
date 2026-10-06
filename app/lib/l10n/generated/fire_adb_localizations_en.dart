// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'fire_adb_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class FireAdbLocalizationsEn extends FireAdbLocalizations {
  FireAdbLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsChinese => 'Chinese';

  @override
  String get settingsEnglish => 'English';

  @override
  String settingsLanguageSaveFailed(Object error) {
    return 'Could not save language settings: $error';
  }

  @override
  String get homeConnectionSucceeded => 'Connected';

  @override
  String homeConnectedDevice(Object serial) {
    return 'Connected: $serial';
  }

  @override
  String get homeConnectionFailed => 'Connection failed';

  @override
  String get homeInvalidInput => 'Invalid input';

  @override
  String get homeInvalidHostPort =>
      'Enter a valid host address and port (1–65535).';

  @override
  String get homeDeviceUnavailable => 'Device unavailable';

  @override
  String get homeAdbDeviceMissing =>
      'This device is not in the ADB device list. Connect the device and refresh the list first.';

  @override
  String get homeDeviceDisconnected => 'Device disconnected';

  @override
  String get homeDisconnectSucceeded => 'Disconnected';

  @override
  String get homeDisconnectFailed => 'Disconnect failed';

  @override
  String get homeManualConnection => 'Manual connection';

  @override
  String get homeHostAddress => 'Host address';

  @override
  String get homeHostAddressExample => 'For example, 192.168.1.100';

  @override
  String get homePort => 'Port';

  @override
  String get homeConnecting => 'Connecting…';

  @override
  String get commonConnect => 'Connect';

  @override
  String get homeDeviceDiscovery => 'Device discovery (mDNS)';

  @override
  String get homeScanning => 'Scanning…';

  @override
  String get homeScan => 'Scan';

  @override
  String get homeWifiDebugInfo =>
      'For Android 11+ devices with Wireless debugging enabled';

  @override
  String get homeMdnsHelp =>
      '✅ Discoverable:\n• Settings → Developer options → Wireless debugging is enabled\n• Phone and computer are on the same Wi-Fi network (no AP isolation)\n\n❌ Not discoverable:\n• USB debugging is enabled but Wireless debugging is off\n• Devices connected manually with `adb connect IP:PORT`\n• Android versions below 11 or ROMs without mDNS broadcasting\n\n💡 If no devices are found, enter an IP address and port in Manual connection above.';

  @override
  String homeScanFailed(Object error) {
    return 'Scan failed: $error';
  }

  @override
  String get homeNoDevicesFound =>
      'No devices found. Check the requirements above or use Manual connection.';

  @override
  String get homeServiceAdbTransport => 'ADB transport';

  @override
  String get homeServiceTlsConnection => 'TLS connection';

  @override
  String get homeServicePairing => 'Pairing service';

  @override
  String homeDeviceCount(int count) {
    return 'Devices ($count)';
  }

  @override
  String get homeRefreshAdbDevices => 'Refresh ADB device list';

  @override
  String homeAdbDevicesReadError(Object error) {
    return 'Could not read the ADB device list: $error';
  }

  @override
  String get homeNoAdbDevices => 'The ADB server did not find any devices.';

  @override
  String get homeFireAdbConnected => 'Connected in FireAdb';

  @override
  String get commonDisconnect => 'Disconnect';

  @override
  String get homeUsbConnectionUnavailable => 'USB connection unavailable';

  @override
  String get homeDeviceOnline => 'Online';

  @override
  String get homeDeviceOffline => 'Offline';

  @override
  String get homeDeviceUnauthorized => 'Unauthorized';

  @override
  String get homeDeviceBootloader => 'Bootloader';

  @override
  String get homeDeviceRecovery => 'Recovery';

  @override
  String get homeDeviceSideload => 'Sideload';

  @override
  String get homeDeviceUnknownState => 'Unknown state';

  @override
  String get homeHistoryConnections => 'Connection history';

  @override
  String get homeNoHistory => 'No connection history';

  @override
  String get homeRemoveHistory => 'Remove from history';

  @override
  String get workspaceBackToHome => 'Back to home';

  @override
  String get workspaceFeatures => 'Features';

  @override
  String get workspaceDeviceDisconnectedTitle => 'Device disconnected';

  @override
  String get workspaceSwitchToOtherDevice => 'Switch to another device';

  @override
  String get workspaceBackToConnections => 'Back to connections';

  @override
  String get workspaceOverviewTitle => 'Device overview';

  @override
  String get workspaceOverviewDescription =>
      'Device model, brand, Android version, and other details';

  @override
  String get workspaceAppsTitle => 'Device apps';

  @override
  String get workspaceAppsDescription =>
      'View installed apps, uninstall apps, and install APKs';

  @override
  String get workspaceTransferTitle => 'File transfer';

  @override
  String get workspaceTransferDescription =>
      'Push files to a device or pull files from it';

  @override
  String get workspaceFilesTitle => 'File manager';

  @override
  String get workspaceFilesDescription =>
      'Browse device storage, download, delete, and share files';

  @override
  String get workspaceScreenshotTitle => 'Screenshot';

  @override
  String get workspaceScreenshotDescription =>
      'Capture the screen with screencap -p and save it as PNG';

  @override
  String get workspaceScreenrecordTitle => 'Screen recording';

  @override
  String get workspaceScreenrecordDescription =>
      'Record the device screen with screenrecord';

  @override
  String get workspaceShellTitle => 'Command shell';

  @override
  String get workspaceShellDescription =>
      'Run adb shell commands and view their output';

  @override
  String get workspacePlanned => 'Planned';

  @override
  String get workspaceFeaturePlannedDescription =>
      'This feature is planned for a future release.';

  @override
  String get deviceOverviewModel => 'Device model';

  @override
  String get deviceOverviewManufacturer => 'Manufacturer';

  @override
  String get deviceOverviewBrand => 'Brand';

  @override
  String get deviceOverviewAndroidVersion => 'Android version';

  @override
  String get deviceOverviewApiLevel => 'API level';

  @override
  String get deviceOverviewNotConnected => 'Device is not connected';

  @override
  String deviceOverviewNetworkConnection(Object host, int port) {
    return 'Network connection · $host:$port';
  }

  @override
  String get deviceOverviewConnected => 'Connected';

  @override
  String deviceOverviewInfoReadFailed(Object error) {
    return 'Could not read device information: $error';
  }

  @override
  String get deviceOverviewBasicInformation => 'Basic information';

  @override
  String get shellOutputSettings => 'Shell output settings';

  @override
  String get shellDeviceNotConnected => 'Device is not connected';

  @override
  String shellMaxRetainedOutput(int limit) {
    return 'Maximum retained output: $limit MiB';
  }

  @override
  String get shellOutputLimitNote =>
      'There is no line limit. When the size limit is reached, only the oldest output is removed.';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonSettingsSaveFailed => 'Could not save settings';

  @override
  String get shellClearOutput => 'Clear output';

  @override
  String get shellAbortCurrentCommand => 'Stop the current command';

  @override
  String get shellSendCtrlC => 'Send Ctrl+C';

  @override
  String get shellEmptyPrompt =>
      'Enter a command and press Enter to run\n↑/↓ Browse command history\nWhile running, enter text and press Enter to send it; use Stop to abort\nCommon: ls, ps, logcat, dumpsys, top, df';

  @override
  String get shellRunningHint =>
      'Type in the current shell and press Enter to send';

  @override
  String get shellCommandHint => 'Enter a command (e.g. ls -la /sdcard)';

  @override
  String get shellInteractiveHint => 'Interactive shell · type exit to quit';

  @override
  String get shellRunningSessionHint =>
      'Session running · input is sent to the current process';

  @override
  String get shellCommandAborted => '^C (aborted)';

  @override
  String shellCommandError(Object error) {
    return 'Error: $error';
  }

  @override
  String shellSendInputFailed(Object error) {
    return 'Could not send input: $error';
  }

  @override
  String get shellEarlierOutputOmitted => '…earlier output omitted…';
}
