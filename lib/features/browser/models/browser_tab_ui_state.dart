import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Encapsulates the UI-specific visual state, favicon cache, preview image,
/// theme color, and scroll offset of a browser tab.
class BrowserTabUiState {
  String title;
  Color? themeColor;
  String? findQuery;
  Uint8List? previewBytes;
  int savedScrollY;
  String? tabGroupId;
  bool hasVideoElement;
  int lastVisitedAtMs;
  String? faviconUrl;

  Uint8List? _faviconBytes;
  Uint8List? get faviconBytes => _faviconBytes;
  set faviconBytes(Uint8List? bytes) {
    if (bytes != null && bytes.isNotEmpty) {
      if (bytes.length > 512 * 1024) {
        _faviconBytes = null;
      } else {
        _faviconBytes = Uint8List.fromList(bytes);
      }
    } else {
      _faviconBytes = null;
    }
  }

  int get faviconBytesSize => _faviconBytes?.length ?? 0;

  BrowserTabUiState({
    this.title = '',
    this.themeColor,
    this.findQuery,
    this.previewBytes,
    this.savedScrollY = 0,
    this.tabGroupId,
    this.hasVideoElement = false,
    int? lastVisitedAtMs,
    this.faviconUrl,
    Uint8List? faviconBytes,
  }) : lastVisitedAtMs = lastVisitedAtMs ?? DateTime.now().millisecondsSinceEpoch {
    this.faviconBytes = faviconBytes;
  }
}
