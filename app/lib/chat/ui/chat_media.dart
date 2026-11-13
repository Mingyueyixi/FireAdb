import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/fireadb_localizations_ext.dart';

class ChatMediaGrid extends StatelessWidget {
  const ChatMediaGrid({
    super.key,
    required this.paths,
    this.onTap,
    this.onRemove,
  });

  final List<String?> paths;
  final void Function(int index)? onTap;
  final void Function(int index)? onRemove;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    if (paths.length == 1) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280, maxHeight: 220),
          child: _tile(context, 0, fit: BoxFit.contain, expand: false),
        ),
      );
    }
    final columns = paths.length == 2 || paths.length == 4 ? 2 : 3;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: paths.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemBuilder: (context, index) => _tile(context, index, fit: BoxFit.cover, expand: true),
    );
  }

  Widget _tile(
    BuildContext context,
    int index, {
    required BoxFit fit,
    required bool expand,
  }) {
    final path = paths[index];
    return GestureDetector(
      onTap: path == null ? null : () => onTap?.call(index),
      child: Stack(
        fit: expand ? StackFit.expand : StackFit.loose,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _picture(context, path, fit),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 2,
              right: 2,
              child: IconButton.filledTonal(
                tooltip: context.l10n.chatRemoveImage,
                visualDensity: VisualDensity.compact,
                onPressed: () => onRemove!(index),
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
        ],
      ),
    );
  }

  Widget _picture(BuildContext context, String? path, BoxFit fit) {
    if (path != null && File(path).existsSync()) {
      return Image.file(File(path), fit: fit);
    }
    return Center(child: Text(context.l10n.chatImagePending));
  }
}
