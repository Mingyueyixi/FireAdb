import '../apps/data/bean/app_freeze.dart';

/// `adb root` 成功后，这条连接上的 shell 和 sync 都是 root。
/// 设备不允许时改用 [binary]。`-c`、`0 sh -c`、`root sh -c` 哪种能跑通记哪一种。
enum SuForm { dashC, uid, user }

class RootPlan {
  const RootPlan.adb() : binary = '', form = SuForm.dashC, adbRoot = true;

  const RootPlan.su(this.binary, this.form) : adbRoot = false;

  final bool adbRoot;
  final String binary;
  final SuForm form;

  String wrap(String command) {
    if (adbRoot) return command;
    final bin = quoteShellArg(binary);
    final cmd = quoteShellArg(command);
    return switch (form) {
      SuForm.dashC => '$bin -c $cmd',
      SuForm.uid => '$bin 0 sh -c $cmd',
      SuForm.user => '$bin root sh -c $cmd',
    };
  }
}

final _plans = <String, RootPlan>{};

void clearRootPlans() => _plans.clear();

void forgetRootPlansFor(String serial) {
  _plans.removeWhere((key, _) => key.startsWith('$serial\n'));
}

RootPlan? cachedRootPlan(String key) => _plans[key];

void rememberRootPlan(String key, RootPlan plan) => _plans[key] = plan;

/// 输出里出现 `uid=0` 才算 root。
bool isRootIdentity(String output) {
  return RegExp(r'uid=0(\(|\s|$)').hasMatch(output);
}
