import 'package:adb_core/adb_core.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../connection/connection_manager.dart';

class HomeController extends GetxController {
  final TextEditingController hostController = TextEditingController();
  final TextEditingController portController =
      TextEditingController(text: '5555');
  final RxBool connecting = false.obs;
  final RxBool scanning = false.obs;
  final RxList<MdnsService> discovered = <MdnsService>[].obs;
  final RxnString scanError = RxnString();

  ConnectionManager get manager => Get.find<ConnectionManager>();

  Future<AdbDevice> connect(String host, int port) async {
    connecting.value = true;
    try {
      return await manager.connectHost(host, port);
    } finally {
      connecting.value = false;
    }
  }

  Future<void> scan() async {
    scanning.value = true;
    scanError.value = null;
    try {
      discovered.assignAll(
        await discoverAdbServices(
          serviceTypes: const <String>{
            adbServiceTypeTransport,
            adbServiceTypeConnect,
            adbServiceTypePairing,
          },
        ),
      );
    } catch (error) {
      scanError.value = '$error';
    } finally {
      scanning.value = false;
    }
  }

  @override
  void onClose() {
    hostController.dispose();
    portController.dispose();
    super.onClose();
  }
}
