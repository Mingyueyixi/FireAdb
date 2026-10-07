import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'data/feature_spec.dart';

/// 工作区当前看哪台设备，以及每台设备各自停在哪个功能。
///
/// 宽屏和窄屏共用 [featureCacheKey] 指向的那一份页面，避免同一功能出现两套状态。
class WorkspaceController extends GetxController {
  WorkspaceController(String serial) : selectedSerial = serial.obs;

  final RxString selectedSerial;
  final GlobalKey featureCacheKey = GlobalKey();
  final RxBool narrowFeatureOpen = false.obs;
  final Map<String, String> _featureBySerial = <String, String>{};
  final RxString _currentFeature = kOverviewFeatureId.obs;

  String get currentFeatureId => _currentFeature.value;

  void selectSerial(String serial) {
    if (serial == selectedSerial.value) return;
    _featureBySerial[selectedSerial.value] = _currentFeature.value;
    selectedSerial.value = serial;
    _currentFeature.value = _featureBySerial[serial] ?? kOverviewFeatureId;
  }

  void selectFeature(String featureId) {
    if (featureId == _currentFeature.value) return;
    _featureBySerial[selectedSerial.value] = featureId;
    _currentFeature.value = featureId;
  }

  void openFeature(String featureId) {
    selectFeature(featureId);
    narrowFeatureOpen.value = true;
  }

  void closeFeature() => narrowFeatureOpen.value = false;
}
