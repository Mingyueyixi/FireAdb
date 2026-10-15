import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/fire_adb_localizations_ext.dart';

class FilesToolbar extends StatelessWidget {
  const FilesToolbar({
    super.key,
    required this.selecting,
    required this.busy,
    required this.searching,
    required this.canPaste,
    required this.selectedCount,
    required this.onUpload,
    required this.onCreate,
    required this.onSearch,
    required this.onClearSearch,
    required this.onToggleSelecting,
    required this.onSelectAll,
    required this.onExport,
    required this.onDelete,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.onPermission,
  });

  final bool selecting;
  final bool busy;
  final bool searching;
  final bool canPaste;
  final int selectedCount;
  final VoidCallback onUpload;
  final VoidCallback onCreate;
  final VoidCallback onSearch;
  final VoidCallback onClearSearch;
  final VoidCallback onToggleSelecting;
  final VoidCallback onSelectAll;
  final VoidCallback onExport;
  final VoidCallback onDelete;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback onPermission;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = !busy;
    return _ScrollingIconRow(
      children: <Widget>[
        IconButton(
          tooltip: l10n.filesUpload,
          onPressed: enabled ? onUpload : null,
          icon: const Icon(Icons.upload_file),
        ),
        IconButton(
          tooltip: l10n.filesCreate,
          onPressed: enabled ? onCreate : null,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
        IconButton(
          tooltip: l10n.filesSearch,
          onPressed: enabled ? onSearch : null,
          icon: const Icon(Icons.search),
        ),
        if (searching)
          TextButton(
            onPressed: enabled ? onClearSearch : null,
            child: Text(l10n.filesClearSearch),
          ),
        IconButton(
          tooltip: selecting ? l10n.filesClearSelection : l10n.filesSelect,
          onPressed: enabled ? onToggleSelecting : null,
          icon: Icon(selecting ? Icons.close : Icons.checklist),
        ),
        if (selecting) ...<Widget>[
          IconButton(
            tooltip: l10n.filesSelectAll,
            onPressed: enabled ? onSelectAll : null,
            icon: const Icon(Icons.select_all),
          ),
          IconButton(
            tooltip: l10n.filesExport,
            onPressed: enabled && selectedCount > 0 ? onExport : null,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: l10n.filesCopy,
            onPressed: enabled && selectedCount > 0 ? onCopy : null,
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: l10n.filesCut,
            onPressed: enabled && selectedCount > 0 ? onCut : null,
            icon: const Icon(Icons.content_cut),
          ),
          IconButton(
            tooltip: l10n.filesPermission,
            onPressed: enabled && selectedCount > 0 ? onPermission : null,
            icon: const Icon(Icons.lock_outline),
          ),
          IconButton(
            tooltip: l10n.filesDelete,
            onPressed: enabled && selectedCount > 0 ? onDelete : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
        if (canPaste)
          IconButton(
            tooltip: l10n.filesPaste,
            onPressed: enabled ? onPaste : null,
            icon: const Icon(Icons.paste),
          ),
      ],
    );
  }
}

class _ScrollingIconRow extends StatefulWidget {
  const _ScrollingIconRow({required this.children});

  final List<Widget> children;

  @override
  State<_ScrollingIconRow> createState() => _ScrollingIconRowState();
}

class _ScrollingIconRowState extends State<_ScrollingIconRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.haveDimensions || position.maxScrollExtent <= 0) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      if (!_controller.hasClients) return;
      _controller.position.pointerScroll(delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const <PointerDeviceKind>{
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.trackpad,
          },
        ),
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: ListView(
            controller: _controller,
            primary: false,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: widget.children,
          ),
        ),
      ),
    );
  }
}
