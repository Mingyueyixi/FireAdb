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
  String get settingsTitle => 'Settings';

  @override
  String get settingsPreferSdkAdb => 'Prefer the SDK adb server';

  @override
  String get settingsChooseLanguage => 'Choose language';

  @override
  String get settingsAdbServerPort => 'FireAdb server port';

  @override
  String get settingsAdbServerPortHelp =>
      'The default is 5037. After you apply a change, FireAdb restarts its own server on the new port, and this app\'s device list connects there. Other adb clients still connect to the adb server on 5037. If nothing is listening on 5037, adb starts a server there itself.';

  @override
  String get settingsApply => 'Apply';

  @override
  String get settingsAdbServerPortInvalid => 'Enter a port from 1 to 65535';

  @override
  String get settingsPreferSdkAdbHelp =>
      'When adb is found on this computer, it starts on the port above instead of FireAdb listening itself.';

  @override
  String settingsSdkAdbPath(Object path) {
    return 'Found $path';
  }

  @override
  String get settingsSdkAdbMissing =>
      'adb was not found. FireAdb\'s own server is still used.';

  @override
  String settingsSdkAdbStartFailed(Object error) {
    return 'Could not start the SDK adb server: $error';
  }

  @override
  String settingsLanguageSaveFailed(Object error) {
    return 'Could not save language settings: $error';
  }

  @override
  String get settingsAutoRefreshMdns => 'Auto-refresh mDNS';

  @override
  String get settingsAutoRefreshDevices => 'Auto-refresh device list';

  @override
  String settingsAutoRefreshHelp(int seconds) {
    return 'When checked, refresh every $seconds seconds';
  }

  @override
  String get settingsAutoRefreshInterval => 'Refresh interval (seconds)';

  @override
  String get settingsAutoRefreshIntervalInvalid =>
      'Enter a whole number of seconds from 1 to 3600';

  @override
  String get homeAutoRefresh => 'Auto refresh';

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
      '1. Pairing service: open the pairing code screen first. A floating window or split screen is recommended, because leaving that screen closes the service.\n2. Tap Scan on this page. When the pairing service appears, tap Pair.\n3. Enter the wireless debugging pairing code.\n4. Tap the matching wireless debugging port to connect.\nIf already paired, connect directly.';

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
  String get homePair => 'Pair';

  @override
  String get homePairingTitle => 'Wireless pairing';

  @override
  String get homePairingCodeHelp =>
      'Enter the pairing code shown on the wireless debugging screen.';

  @override
  String get homePairingSucceeded => 'Pairing succeeded';

  @override
  String get homePairingSucceededHint =>
      'Tap the matching wireless debugging port to connect.';

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
  String homeUsbDevicesReadError(Object error) {
    return 'Could not read USB devices: $error';
  }

  @override
  String get homeNoAdbDevices => 'The ADB server did not find any devices.';

  @override
  String get homeAdbServerUnavailable =>
      'The local ADB server is unavailable, so the device list cannot refresh.';

  @override
  String homeAdbServerNotRunning(Object port) {
    return 'No ADB server is listening on 127.0.0.1:$port. USB devices are listed directly. Connect network devices manually or scan for them.';
  }

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
      'View installed apps, export APKs, uninstall, and freeze apps';

  @override
  String get workspaceTransferTitle => 'File transfer';

  @override
  String get workspaceTransferDescription =>
      'Push files to a device or pull files from it';

  @override
  String get workspaceFilesTitle => 'File manager';

  @override
  String get workspaceFilesDescription =>
      'Browse device files, edit and search them, change permissions, export them, and upload from this computer';

  @override
  String get workspaceScreenshotTitle => 'Screenshot';

  @override
  String get workspaceScreenshotDescription =>
      'Capture the screen with screencap -p and save the PNG in the app directory';

  @override
  String get workspaceScreenrecordTitle => 'Screen recording';

  @override
  String get workspaceScreenrecordDescription =>
      'Record the screen and save it in the app directory, using the system or built-in recorder';

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
  String get commonClose => 'Close';

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

  @override
  String get appsSearchHint => 'Search by app name or package name';

  @override
  String get appsFilterUser => 'User apps';

  @override
  String get appsFilterSystem => 'System apps';

  @override
  String get appsFilterFrozen => 'Frozen';

  @override
  String get appsFilterAll => 'All';

  @override
  String get appsRefresh => 'Refresh app list';

  @override
  String appsCount(int count) {
    return '$count apps';
  }

  @override
  String get appsEmpty => 'No apps match the current filters';

  @override
  String appsLoadFailed(Object error) {
    return 'Could not load the app list: $error';
  }

  @override
  String appsVersion(Object version) {
    return 'Version $version';
  }

  @override
  String appsSize(Object size) {
    return 'Size $size';
  }

  @override
  String appsPath(Object path) {
    return 'Path $path';
  }

  @override
  String get appsFrozenBadge => 'Frozen';

  @override
  String get appsDisabledBadge => 'Disabled';

  @override
  String get appsSuspendedBadge => 'Suspended';

  @override
  String get appsAmFrozenBadge => 'AM frozen';

  @override
  String get appsFreezeMethod => 'Freeze method';

  @override
  String get appsFreezeTitle => 'Freeze app';

  @override
  String get appsUnfreezeTitle => 'Unfreeze app';

  @override
  String appsFreezePrompt(Object name) {
    return 'Choose how to freeze $name';
  }

  @override
  String appsUnfreezePrompt(Object name) {
    return 'Choose how to unfreeze $name';
  }

  @override
  String get appsFreezeMethodDisableUser => 'Disable app';

  @override
  String get appsFreezeMethodDisableUserDescription =>
      'pm disable-user: disables the app for the user so it cannot start. Works on most devices.';

  @override
  String get appsFreezeMethodSuspend => 'Suspend app';

  @override
  String get appsFreezeMethodSuspendDescription =>
      'pm suspend: hides and pauses the app while keeping its data.';

  @override
  String get appsFreezeMethodAmFreeze => 'AM freeze';

  @override
  String get appsFreezeMethodAmFreezeDescription =>
      'am freeze: ActivityManager process freeze. Requires Android 15+.';

  @override
  String get appsExportAction => 'Export APK';

  @override
  String get appsExportTitle => 'Export app';

  @override
  String appsExportPrompt(Object name) {
    return 'Choose the folder where $name should be pulled';
  }

  @override
  String get appsExportDirectory => 'Destination folder';

  @override
  String appsExportSucceeded(Object path) {
    return 'Exported to $path';
  }

  @override
  String get appsUninstallAction => 'Uninstall';

  @override
  String get appsUninstallTitle => 'Uninstall app';

  @override
  String appsUninstallConfirm(Object name, Object packageName) {
    return 'Uninstall $name ($packageName)?';
  }

  @override
  String get appsUninstallSystemTitle => 'Uninstall system app';

  @override
  String appsUninstallSystemConfirm(Object name, Object packageName) {
    return '$name ($packageName) is a system app. Uninstalling it may break related features and is usually hard to undo. Continue?';
  }

  @override
  String get appsUninstallCoreTitle => 'Uninstall core system app';

  @override
  String appsUninstallCoreConfirm(Object name, Object packageName) {
    return '$name ($packageName) is a core system component. Uninstalling it may prevent the device from booting, showing a home screen, making calls, or opening Settings, and is very hard to undo. Uninstall it anyway?';
  }

  @override
  String get appsUninstallConfirmAction => 'Uninstall anyway';

  @override
  String appsUninstallSucceeded(Object name) {
    return 'Uninstalled $name';
  }

  @override
  String get appsFreezeSystemTitle => 'Freeze system app';

  @override
  String appsFreezeSystemConfirm(Object name, Object packageName) {
    return '$name ($packageName) is a system app. Freezing it may break related features. Continue?';
  }

  @override
  String get appsFreezeCoreTitle => 'Freeze core system app';

  @override
  String appsFreezeCoreConfirm(Object name, Object packageName) {
    return '$name ($packageName) is a core system component. Freezing it may prevent the device from booting, showing a home screen, making calls, or opening Settings. Freeze it anyway?';
  }

  @override
  String get appsFreezeConfirmAction => 'Freeze anyway';

  @override
  String get appsFreezeAction => 'Freeze';

  @override
  String get appsUnfreezeAction => 'Unfreeze';

  @override
  String appsFreezeSucceeded(Object name) {
    return 'Froze $name';
  }

  @override
  String appsUnfreezeSucceeded(Object name) {
    return 'Unfroze $name';
  }

  @override
  String get appsActionFailed => 'Action failed';

  @override
  String get appsSelect => 'Select';

  @override
  String get appsSelectDone => 'Done';

  @override
  String get appsSelectAll => 'Select all';

  @override
  String get appsSelectClear => 'Clear';

  @override
  String appsSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String appsBatchUninstallConfirm(int count) {
    return 'Uninstall the $count selected apps?';
  }

  @override
  String appsBatchUninstallSystemConfirm(int count, Object names) {
    return 'The $count selected apps include system apps ($names). Uninstalling them may break related features and is usually hard to undo. Continue?';
  }

  @override
  String appsBatchUninstallCoreConfirm(int count, Object names) {
    return 'The $count selected apps include core system components ($names). Uninstalling them may prevent the device from booting, showing a home screen, making calls, or opening Settings, and is very hard to undo. Uninstall them anyway?';
  }

  @override
  String appsBatchFreezeConfirm(int count) {
    return 'Freeze the $count selected apps?';
  }

  @override
  String appsBatchFreezeSystemConfirm(int count, Object names) {
    return 'The $count selected apps include system apps ($names). Freezing them may break related features. Continue?';
  }

  @override
  String appsBatchFreezeCoreConfirm(int count, Object names) {
    return 'The $count selected apps include core system components ($names). Freezing them may prevent the device from booting, showing a home screen, making calls, or opening Settings. Freeze them anyway?';
  }

  @override
  String appsBatchExportPrompt(int count) {
    return 'Choose the folder where the $count selected apps should be pulled';
  }

  @override
  String appsBatchUninstallSucceeded(int count) {
    return 'Uninstalled $count apps';
  }

  @override
  String appsBatchFreezeSucceeded(int count) {
    return 'Froze $count apps';
  }

  @override
  String appsBatchExportSucceeded(int count, Object path) {
    return 'Exported $count apps to $path';
  }

  @override
  String get appsTaskExport => 'Exporting';

  @override
  String get appsTaskUninstall => 'Uninstalling';

  @override
  String get appsTaskFreeze => 'Freezing';

  @override
  String get appsTaskUnfreeze => 'Unfreezing';

  @override
  String appsTaskProgress(
    Object action,
    Object name,
    int completed,
    int total,
    int percent,
  ) {
    return '$action $name ($completed/$total, $percent%)';
  }

  @override
  String get appsExportMeasuring => 'Calculating size…';

  @override
  String appsExportBytes(Object done, Object total) {
    return '$done / $total';
  }

  @override
  String appsExportPercent(int percent) {
    return '$percent%';
  }

  @override
  String get appsCancelTask => 'Cancel';

  @override
  String get appsTaskCancelled => 'Cancelled';

  @override
  String appsTaskCancelledDone(int count) {
    return 'Cancelled, $count completed';
  }

  @override
  String appsBatchPartial(int succeeded, int failed) {
    return '$succeeded succeeded, $failed failed';
  }

  @override
  String get filesPath => 'Device path';

  @override
  String get filesUp => 'Parent folder';

  @override
  String get filesRefresh => 'Refresh';

  @override
  String get filesUpload => 'Upload';

  @override
  String get filesCreate => 'New';

  @override
  String get filesFile => 'File';

  @override
  String get filesFolder => 'Folder';

  @override
  String get filesLink => 'Link';

  @override
  String get filesName => 'Name';

  @override
  String get filesSearch => 'Search';

  @override
  String get filesSearchHint => 'Search by name in this folder';

  @override
  String get filesClearSearch => 'Clear search';

  @override
  String filesSearching(Object keyword) {
    return 'Search results for \"$keyword\"';
  }

  @override
  String get filesSearchEmpty => 'No matching files';

  @override
  String get filesEmpty => 'This folder is empty';

  @override
  String get filesSelect => 'Select';

  @override
  String get filesClearSelection => 'Cancel selection';

  @override
  String get filesSelectAll => 'Select all';

  @override
  String get filesOpen => 'Open';

  @override
  String get filesDelete => 'Delete';

  @override
  String filesDeleteConfirm(Object name) {
    return 'Delete $name? This cannot be undone';
  }

  @override
  String filesBatchDeleteConfirm(int count) {
    return 'Delete the $count selected items? This cannot be undone';
  }

  @override
  String filesDeleted(int count) {
    return 'Deleted $count items';
  }

  @override
  String get filesRename => 'Rename';

  @override
  String get filesRenamed => 'Renamed';

  @override
  String get filesInvalidName => 'The name cannot be empty or contain /';

  @override
  String get filesCopy => 'Copy';

  @override
  String get filesCut => 'Cut';

  @override
  String get filesPaste => 'Paste';

  @override
  String get filesPasteIntoSelf => 'A folder cannot be pasted into itself';

  @override
  String filesPasted(int count) {
    return 'Pasted $count items';
  }

  @override
  String filesClipboardCopied(int count) {
    return 'Copied $count items. Paste them into another folder';
  }

  @override
  String filesClipboardCut(int count) {
    return 'Cut $count items. Paste them into another folder';
  }

  @override
  String get filesEdit => 'Edit';

  @override
  String filesEditTitle(Object name) {
    return 'Edit $name';
  }

  @override
  String get filesEditTooLarge =>
      'Files larger than 512 KB cannot be edited here';

  @override
  String get filesEditBinary => 'This is not a text file';

  @override
  String get filesSaved => 'Saved';

  @override
  String get filesPermission => 'Permissions';

  @override
  String get filesPermissionHint => 'Octal mode, for example 644';

  @override
  String get filesInvalidPermission => 'Enter a 3 or 4 digit octal mode';

  @override
  String get filesPermissionUpdated => 'Permissions updated';

  @override
  String filesCreated(Object name) {
    return 'Created $name';
  }

  @override
  String get filesExport => 'Export';

  @override
  String filesExportPrompt(Object name) {
    return 'Choose the folder where $name should be exported';
  }

  @override
  String filesBatchExportPrompt(int count) {
    return 'Choose the folder where the $count selected items should be exported';
  }

  @override
  String filesExportSucceeded(Object path) {
    return 'Exported to $path';
  }

  @override
  String filesUploadSucceeded(int count) {
    return 'Uploaded $count files';
  }

  @override
  String filesOverwrite(Object names) {
    return 'Upload will replace existing files: $names';
  }

  @override
  String filesLoadFailed(Object error) {
    return 'Could not read the folder: $error';
  }

  @override
  String get filesActionFailed => 'Action failed';

  @override
  String get filesTaskDelete => 'Deleting';

  @override
  String get filesTaskRename => 'Renaming';

  @override
  String get filesTaskCopy => 'Copying';

  @override
  String get filesTaskMove => 'Moving';

  @override
  String get filesTaskExport => 'Exporting';

  @override
  String get filesTaskUpload => 'Uploading';

  @override
  String get filesTaskSave => 'Saving';

  @override
  String get filesLocationsStorage => 'Internal storage';

  @override
  String get filesLocationsTemp => 'Temp';

  @override
  String get filesLocationsRoot => 'Root';

  @override
  String get captureDirectoryUnavailable =>
      'The app directory is unavailable, so the file cannot be saved';

  @override
  String captureSaved(Object path) {
    return 'Saved to $path';
  }

  @override
  String get captureSaveLocation => 'Save location';

  @override
  String get captureOpenFolder => 'Open app directory';

  @override
  String get captureOpenFile => 'Open';

  @override
  String captureOpenFailed(Object error) {
    return 'Could not open: $error';
  }

  @override
  String get captureRefresh => 'Refresh';

  @override
  String get captureDelete => 'Delete';

  @override
  String captureDeleteConfirm(Object name) {
    return 'Delete $name from the app directory?';
  }

  @override
  String captureDeleted(Object name) {
    return 'Deleted $name';
  }

  @override
  String get captureActionFailed => 'Action failed';

  @override
  String captureDeviceOutput(Object output) {
    return 'Device output: $output';
  }

  @override
  String captureFailedWithRemote(Object error, Object path) {
    return '$error. The temporary file is still on the device at $path';
  }

  @override
  String get captureEmptyScreenshots =>
      'No screenshots in the app directory yet';

  @override
  String get captureEmptyRecordings => 'No recordings in the app directory yet';

  @override
  String get screenshotCapture => 'Capture screen';

  @override
  String get screenshotCapturing => 'Capturing the screen…';

  @override
  String get screenshotInvalid => 'The device did not return a valid PNG';

  @override
  String get screenrecordStart => 'Start recording';

  @override
  String get screenrecordStop => 'Stop and save';

  @override
  String get screenrecordSaving => 'Saving to the app directory…';

  @override
  String get screenrecordRecording => 'Recording';

  @override
  String get screenrecordTimeLimit => 'Time limit';

  @override
  String get screenrecordLimit30 => '30 seconds';

  @override
  String get screenrecordLimit60 => '1 minute';

  @override
  String get screenrecordLimit180 => '3 minutes';

  @override
  String get screenrecordLimitNone => 'No limit';

  @override
  String get screenrecordTimeLimitNote =>
      'Android 13 and earlier reject recordings longer than 3 minutes.';

  @override
  String get screenrecordTimeLimitUnlimited =>
      'This device has no maximum length. You can choose no limit.';

  @override
  String get screenrecordHint =>
      'When recording stops, the video is saved to the app directory and the temporary video is removed from the device.';

  @override
  String get screenrecordMethod => 'Recorder';

  @override
  String get screenrecordMethodSystem => 'System';

  @override
  String get screenrecordMethodSystemSubtitle =>
      'Use the screenrecord program that comes with the device';

  @override
  String get screenrecordMethodBuiltin => 'Built-in';

  @override
  String get screenrecordMethodBuiltinSubtitle =>
      'Encode with the helper service. The display goes straight into the encoder.';

  @override
  String get screenrecordMethodScrcpy => 'Mirroring';

  @override
  String get screenrecordMethodScrcpySubtitle =>
      'Coming later. The same connection will also be used for preview and remote control.';

  @override
  String get screenrecordShellCopyFailed =>
      'Could not prepare the recorder in the device temp directory';

  @override
  String get screenrecordShellUnsafe =>
      'The recorder in the temp directory would still be taken over by system policy, so it was not started. The file was left in place';

  @override
  String get screenrecordTimeLimitBuiltin =>
      'The built-in recorder has no maximum length. You can choose no limit.';

  @override
  String get screenrecordNoWritableDir =>
      'The shell user cannot create the recording for read and write';

  @override
  String get screenrecordMissing => 'The device did not produce a video file';

  @override
  String screenrecordInvalid(Object path) {
    return 'The recording is not a valid video and remains on the device at $path';
  }

  @override
  String screenrecordTooLarge(Object size, Object path) {
    return 'The recording is $size, which is too large to save here. It remains on the device at $path';
  }

  @override
  String get storageAccessTitle => 'Storage access required';

  @override
  String get storageAccessMessage =>
      'Browsing and saving folders on this phone requires all-files access.';

  @override
  String get storageAccessGrant => 'Grant access';

  @override
  String get localPickerChooseFolder => 'Choose a folder';

  @override
  String get localPickerChooseFiles => 'Choose files';

  @override
  String get localPickerUseFolder => 'Use this folder';

  @override
  String localPickerUseFiles(int count) {
    return 'Select ($count)';
  }

  @override
  String get localPickerStorage => 'Storage';

  @override
  String get localPickerInternalStorage => 'Internal storage';

  @override
  String get localPickerEmpty => 'This folder is empty';

  @override
  String get localPickerUnreadable => 'This folder cannot be read';

  @override
  String get localPickerNewFolder => 'New folder';

  @override
  String get localPickerInvalidName => 'The name cannot contain / or \\';

  @override
  String get localPickerUp => 'Up';

  @override
  String get localPickerGo => 'Go';
}
