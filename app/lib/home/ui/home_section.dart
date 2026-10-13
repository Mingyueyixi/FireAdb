import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';

/// 区块标题。窄宽度时标题省略，避免把图标挤出屏幕。
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              titleText,
            ],
          );
        }
        return Row(
          children: <Widget>[
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(child: titleText),
          ],
        );
      },
    );
  }
}

/// 标题和右侧操作放在一行；窄宽度时操作换到下一行。
///
/// [inline] 为 true 时，操作始终和标题同一行，并与标题垂直居中。
/// 空间不够时标题省略，操作不换行。
class HomeSectionBar extends StatelessWidget {
  const HomeSectionBar({
    super.key,
    required this.header,
    required this.actions,
    this.inline = false,
  });

  final Widget header;
  final List<Widget> actions;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final actionWrap = Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: actions,
    );
    if (inline) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: header),
          const SizedBox(width: 8),
          actionWrap,
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite || constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              header,
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: actionWrap,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: header),
            const SizedBox(width: 8),
            Flexible(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: actionWrap,
              ),
            ),
          ],
        );
      },
    );
  }
}

class HomeAutoRefreshToggle extends StatelessWidget {
  const HomeAutoRefreshToggle({
    super.key,
    required this.checkboxKey,
    required this.value,
    required this.onChanged,
  });

  final Key checkboxKey;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Checkbox(
          key: checkboxKey,
          value: value,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
        GestureDetector(
          onTap: () => onChanged(!value),
          child: Text(context.l10n.homeAutoRefresh),
        ),
      ],
    );
  }
}

/// ListTile 在尾部控件宽于整行时会直接抛异常。窄宽度把操作放到标题下方。
class HomeListTile extends StatelessWidget {
  const HomeListTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.dense = false,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 行尾按钮大约几十到一百多逻辑像素。280 以下改到标题下方，
        // 常见手机宽度仍把操作留在行尾。
        final parkTrailing = trailing != null && constraints.maxWidth < 280;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: dense,
              leading: leading,
              title: title,
              subtitle: subtitle,
              trailing: parkTrailing ? null : trailing,
              onTap: onTap,
            ),
            if (parkTrailing)
              Align(alignment: AlignmentDirectional.centerEnd, child: trailing),
          ],
        );
      },
    );
  }
}

/// 刷新进行时让图标自己转一圈，图标外形保持不变。
class HomeSpinningIcon extends StatefulWidget {
  const HomeSpinningIcon({
    super.key,
    required this.icon,
    required this.spinning,
  });

  final IconData icon;
  final bool spinning;

  @override
  State<HomeSpinningIcon> createState() => _HomeSpinningIconState();
}

class _HomeSpinningIconState extends State<HomeSpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns;

  @override
  void initState() {
    super.initState();
    _turns = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.spinning) _turns.repeat();
  }

  @override
  void didUpdateWidget(HomeSpinningIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning == widget.spinning) return;
    if (widget.spinning) {
      _turns.repeat();
    } else {
      _turns.stop();
      _turns.value = 0;
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(turns: _turns, child: Icon(widget.icon));
  }
}
