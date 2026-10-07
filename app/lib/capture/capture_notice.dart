import '../l10n/generated/fire_adb_localizations.dart';

class CaptureNotice {
  const CaptureNotice({
    required this.title,
    required this.message,
    this.isError = false,
  });

  final String title;
  final String message;
  final bool isError;
}

CaptureNotice captureFailure(FireAdbLocalizations l10n, String message) {
  return CaptureNotice(
    title: l10n.captureActionFailed,
    message: message,
    isError: true,
  );
}

CaptureNotice deviceNotConnectedNotice(FireAdbLocalizations l10n) {
  return captureFailure(l10n, l10n.deviceOverviewNotConnected);
}

CaptureNotice directoryUnavailableNotice(FireAdbLocalizations l10n) {
  return captureFailure(l10n, l10n.captureDirectoryUnavailable);
}

CaptureNotice captureSavedNotice(
  FireAdbLocalizations l10n,
  String path, {
  required String title,
}) {
  return CaptureNotice(title: title, message: l10n.captureSaved(path));
}
