import 'dart:developer' as developer;

import 'package:flutter/material.dart';

void logAppError(String context, Object error, StackTrace stackTrace) {
  developer.log(
    context,
    name: 'fire_adb',
    error: error,
    stackTrace: stackTrace,
    level: 1000,
  );
}

void showAppMessage(
  ScaffoldMessengerState messenger,
  ThemeData theme, {
  required String title,
  required String message,
  bool isError = false,
}) {
  final colors = theme.colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.surfaceContainerHigh,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: isError ? colors.error : colors.primary,
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
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
}
