import 'package:flutter/material.dart';

void showAppMessage(
  ScaffoldMessengerState messenger,
  ThemeData theme, {
  required String title,
  required String message,
  bool isError = false,
}) {
  final colors = theme.colorScheme;
  final background = isError ? colors.error : colors.surfaceContainerHigh;
  final foreground = isError ? colors.onError : colors.onSurface;
  final detail = isError ? colors.onError : colors.onSurfaceVariant;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!messenger.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: background,
          elevation: 6,
          showCloseIcon: isError,
          closeIconColor: isError ? colors.onError : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: Duration(seconds: isError ? 8 : 4),
          content: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                isError ? Icons.error_outline : Icons.info_outline,
                color: isError ? colors.onError : colors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: detail,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
  });
}
