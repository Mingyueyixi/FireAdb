import 'package:get/get.dart';

import 'data/feature_spec.dart';

class WorkspaceController extends GetxController {
  WorkspaceController(String serial) : selectedSerial = serial.obs;

  final RxString selectedSerial;
  final RxString selectedFeature = kOverviewFeatureId.obs;

  void selectSerial(String serial) => selectedSerial.value = serial;

  void selectFeature(String featureId) => selectedFeature.value = featureId;
}
