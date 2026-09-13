import 'package:flutter/material.dart';

import '../../models/feature_spec.dart';
import '../../widgets/feature_tile.dart';

/// 未实现功能的占位页（移动端全屏）。
class PlaceholderFeaturePage extends StatelessWidget {
  const PlaceholderFeaturePage({super.key, required this.spec});

  final FeatureSpec spec;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(spec.title)),
      body: PlaceholderFeatureBody(spec: spec),
    );
  }
}