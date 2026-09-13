# fire_adb（Flutter 应用）

跨平台 ADB 工具箱的 Flutter 界面层：设备列表 / shell 终端 / 文件管理 / 安装构建 / 截图录屏。

工程说明、架构与实现路线见[仓库根 README](../README.md)。

## 目录结构

```
lib/
├── main.dart                    # 应用入口
├── models/                      # 数据模型（device_profile、feature_spec）
├── screens/                     # 页面
│   ├── home_screen.dart
│   ├── workspace_screen.dart
│   └── features/                # 各功能页面
├── services/                    # 业务服务（connection_manager 等）
└── widgets/                     # 通用组件
```

## 开发

本应用是仓库 pub workspace 的成员，**请在仓库根**执行依赖与测试命令：

```bash
flutter pub get            # 拉取整个工作区依赖
cd app && flutter run      # 运行（桌面/Android）
flutter test app           # 运行应用测试
```

`run.bat` 为 Windows 下的 `flutter run --verbose` 快捷脚本。
