import 'package:flutter/widgets.dart';

import 'generated/fire_adb_localizations.dart';

extension FireAdbLocalizationsExt on BuildContext {
  FireAdbLocalizations get l10n => FireAdbLocalizations.of(this)!;
}
