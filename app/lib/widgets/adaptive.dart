import 'package:flutter/widgets.dart';

const double kDesktopBreakpoint = 840;
const double kTabletBreakpoint = 600;

bool isWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

bool isAtLeastTablet(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kTabletBreakpoint;