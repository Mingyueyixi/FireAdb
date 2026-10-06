import 'package:flutter/material.dart';

import '../widgets/locale_selector.dart';
import 'data/feature_spec.dart';
import 'feature_tile.dart';

/// 未实现功能的占位页（移动端全屏）。
class PlaceholderFeaturePage extends StatelessWidget {
  const PlaceholderFeaturePage({super.key, required this.spec});

  final FeatureSpec spec;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(featureTitle(context, spec)),
        actions: const <Widget>[LocaleSelector()],
      ),
      body: PlaceholderFeatureBody(spec: spec),
    );
  }
}
