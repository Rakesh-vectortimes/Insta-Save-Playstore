import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_item.dart';

final downloadHistoryProvider =
    StateNotifierProvider<DownloadHistoryNotifier, List<DownloadItem>>((ref) {
  return DownloadHistoryNotifier()..load();
});

enum DownloadSortOption { downloadTime, fileSize }

class DownloadHistoryNotifier extends StateNotifier<List<DownloadItem>> {
  DownloadHistoryNotifier() : super(const []);

  static const _storageKey = 'download_history_v1';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? [];
    state = raw
        .map((e) => DownloadItem.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();
  }

  Future<void> add(DownloadItem item) async {
    state = [item, ...state];
    await _persist();
  }

  Future<void> remove(String id) async {
    state = state.where((item) => item.id != id).toList();
    await _persist();
  }

  List<DownloadItem> filtered({
    DownloadMediaType? type,
    DownloadSortOption sort = DownloadSortOption.downloadTime,
  }) {
    var items = List<DownloadItem>.from(state);
    if (type != null) {
      items = items.where((i) => i.type == type).toList();
    }
    switch (sort) {
      case DownloadSortOption.downloadTime:
        items.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      case DownloadSortOption.fileSize:
        items.sort((a, b) => b.fileSizeBytes.compareTo(a.fileSizeBytes));
    }
    return items;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storageKey,
      state.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }
}
