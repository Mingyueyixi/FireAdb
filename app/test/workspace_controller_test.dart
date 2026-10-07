import 'package:fire_adb/workspace/data/feature_spec.dart';
import 'package:fire_adb/workspace/workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('每台设备记住自己上次选中的功能', () {
    final controller = WorkspaceController('device-a');

    expect(controller.currentFeatureId, kOverviewFeatureId);
    controller.selectFeature('screenshot');
    controller.selectSerial('device-b');

    expect(controller.selectedSerial.value, 'device-b');
    expect(controller.currentFeatureId, kOverviewFeatureId);

    controller.selectFeature('shell');
    controller.selectSerial('device-a');
    expect(controller.currentFeatureId, 'screenshot');

    controller.selectSerial('device-b');
    expect(controller.currentFeatureId, 'shell');
    controller.selectSerial('device-b');
    expect(controller.currentFeatureId, 'shell');

    controller.openFeature('files');
    expect(controller.narrowFeatureOpen.value, isTrue);
    expect(controller.currentFeatureId, 'files');
    controller.closeFeature();
    expect(controller.narrowFeatureOpen.value, isFalse);
    expect(controller.currentFeatureId, 'files');
  });
}
