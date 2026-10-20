import 'package:flutter/material.dart';

import '../services/sync_api.dart';

const teal = Color(0xFF075E61);
const ink = Color(0xFF18353B);

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  final text = error is FormatException
      ? error.message
      : error is SyncFailure
      ? error.message
      : 'Could not save this change. Check device storage and try again.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
