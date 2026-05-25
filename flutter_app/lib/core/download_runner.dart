import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust_api;
import 'diagnostics/diagnostic_log.dart';
import 'notification_service.dart';

/// R69: download status code constants. The wire-level int values come
/// from `core-storage::models::DownloadTask` / `DownloadChapter` (Rust):
///
/// - **Task**: 0=等待, 1=下载中, 2=暂停, 3=完成, 4=失败
/// - **Chapter**: 0=等待, 1=下载中, 2=完成, 3=失败
///
/// Note the off-by-one: chapter "complete" is 2, task "complete" is 3,
/// because tasks have an extra "暂停" state. Treating them as a shared
/// magic-number set has burnt at least one reviewer; keep the two
/// classes separate so the type system catches mix-ups.
class DownloadTaskStatus {
  const DownloadTaskStatus._();
  static const int pending = 0;
  static const int running = 1;
  static const int paused = 2;
  static const int complete = 3;
  static const int failed = 4;
}

class DownloadChapterStatus {
  const DownloadChapterStatus._();
  static const int pending = 0;
  static const int running = 1;
  static const int complete = 2;
  static const int failed = 3;
}

/// R40: scrub a thrown exception's message for the persisted
/// `errorMessage` field. Strips URL query strings (where auth tokens
/// and referer params live) and trims to a UI-friendly length.
String _sanitizeDownloadError(Object e) {
  var msg = e.toString();
  // Replace any http(s)://host[:port]/path?query → http(s)://host[:port]/path
  msg = msg.replaceAllMapped(
    RegExp(r'(https?://[^\s?]+)\?[^\s]*'),
    (m) => '${m.group(1)}?<redacted>',
  );
  if (msg.length > 200) msg = '${msg.substring(0, 200)}…';
  return msg;
}

class _QueuedDownload {
  final String taskId;
  final String bookName;
  final List<Map<String, dynamic>> chapters;
  final String sourceJson;
  final String downloadDir;
  final String dbPath;

  const _QueuedDownload({
    required this.taskId,
    required this.bookName,
    required this.chapters,
    required this.sourceJson,
    required this.downloadDir,
    required this.dbPath,
  });
}

class DownloadRunner {
  /// Process-wide singleton.
  ///
  /// R70 — known UX limitation: this runner serialises tasks. A user
  /// who queues 10 books with 100 chapters each waits for all of them
  /// in turn; there is no concurrency knob. This is intentional for
  /// the current Phase 4 milestone (avoids fighting per-source rate
  /// limits in core-source/parser.rs and keeps the notification
  /// progress bar coherent), but should be reconsidered when we add
  /// download priorities or per-source parallelism.
  static final DownloadRunner _instance = DownloadRunner._();
  factory DownloadRunner() => _instance;
  DownloadRunner._();

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  final List<_QueuedDownload> _queue = [];
  final _completionController = StreamController<String>.broadcast();

  Stream<String> get onTaskCompleted => _completionController.stream;

  void enqueue({
    required String taskId,
    required String bookName,
    required List<Map<String, dynamic>> chapters,
    required String sourceJson,
    required String downloadDir,
    required String dbPath,
  }) {
    _queue.add(_QueuedDownload(
      taskId: taskId,
      bookName: bookName,
      chapters: chapters,
      sourceJson: sourceJson,
      downloadDir: downloadDir,
      dbPath: dbPath,
    ));
    DiagnosticLog.info('download.task', 'Download task created',
        metadata: {'task_id': taskId, 'book_name': bookName, 'chapter_count': chapters.length});
    if (!_isRunning) {
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    _isRunning = true;
    while (_queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      await _download(task);
    }
    _isRunning = false;
  }

  Future<void> _download(_QueuedDownload task) async {
    int successCount = 0;
    int failCount = 0;
    int skipCount = 0;
    final totalChapters = task.chapters.length;
    final notificationId = task.taskId.hashCode.abs();

    if (totalChapters == 0) {
      try {
        await rust_api.updateDownloadTaskStatus(
          dbPath: task.dbPath,
          taskId: task.taskId,
          status: DownloadTaskStatus.failed,
          errorMessage: '无可下载章节',
        );
      } catch (e) {
        debugPrint('[Download] mark empty task failed: $e');
      }
      _completionController.add(task.taskId);
      return;
    }

    try {
      await rust_api.updateDownloadTaskStatus(
        dbPath: task.dbPath,
        taskId: task.taskId,
        status: DownloadTaskStatus.running,
      );
      DiagnosticLog.info('download.task', 'Download task started',
          metadata: {'task_id': task.taskId, 'book_name': task.bookName, 'chapter_count': totalChapters});
    } catch (e) {
      debugPrint('[Download] mark running failed: $e');
    }

    await NotificationService.showDownloadProgress(
      id: notificationId,
      title: task.bookName,
      current: 0,
      total: totalChapters,
    );

    for (var i = 0; i < task.chapters.length; i++) {
      final ch = task.chapters[i];
      final chapterId = '${task.taskId}_$i';
      final chapterUrl = ch['url'] as String? ?? '';
      if (chapterUrl.isEmpty) {
        skipCount++;
        try {
          await rust_api.updateDownloadChapterStatus(
            dbPath: task.dbPath,
            chapterId: chapterId,
            status: DownloadChapterStatus.failed,
            fileSize: 0,
            errorMessage: '章节链接为空',
          );
        } catch (e) {
          debugPrint('[Download] mark empty url chapter failed: $e');
        }
        final processed = successCount + failCount + skipCount;
        await NotificationService.showDownloadProgress(
          id: notificationId,
          title: task.bookName,
          current: processed,
          total: totalChapters,
        );
        continue;
      }
      try {
        await rust_api.downloadAndSaveChapter(
          dbPath: task.dbPath,
          taskId: task.taskId,
          downloadChapterId: chapterId,
          sourceJson: task.sourceJson,
          chapterUrl: chapterUrl,
          downloadDir: task.downloadDir,
        );
        successCount++;
      } catch (e) {
        debugPrint('[Download] chapter $chapterId failed: $e');
        failCount++;
        // P3-8 + R40: surface the real exception in errorMessage so users
        // (or us) can tell "网络超时" from "源不支持" without grepping
        // logcat — but scrub URL query strings first so chapter URLs
        // with auth tokens / referer params don't end up persisted in
        // the download_chapters table. Trim long messages because
        // errorMessage is shown in download UI.
        final shortMsg = _sanitizeDownloadError(e);
        try {
          await rust_api.updateDownloadChapterStatus(
            dbPath: task.dbPath,
            chapterId: chapterId,
            status: DownloadChapterStatus.failed,
            fileSize: 0,
            errorMessage: '下载失败: $shortMsg',
          );
        } catch (innerErr) {
          debugPrint('[Download] mark chapter failed: $innerErr');
        }
      }
      final processed = successCount + failCount + skipCount;
      await NotificationService.showDownloadProgress(
        id: notificationId,
        title: task.bookName,
        current: processed,
        total: totalChapters,
      );
    }

    if (failCount > 0 || skipCount > 0) {
      try {
        await rust_api.updateDownloadTaskStatus(
          dbPath: task.dbPath,
          taskId: task.taskId,
          status: DownloadTaskStatus.failed,
          errorMessage:
              '部分章节下载失败 (成功: $successCount, 失败: $failCount, 跳过: $skipCount)',
        );
      } catch (e) {
        debugPrint('[Download] mark task partial-fail failed: $e');
      }
      DiagnosticLog.warn('download.task', 'Download task finished with errors',
          metadata: {'task_id': task.taskId, 'book_name': task.bookName, 'success': successCount, 'fail': failCount, 'skip': skipCount});
    } else {
      try {
        await rust_api.updateDownloadTaskStatus(
          dbPath: task.dbPath,
          taskId: task.taskId,
          status: DownloadTaskStatus.complete,
        );
      } catch (e) {
        debugPrint('[Download] mark task complete failed: $e');
      }
      DiagnosticLog.info('download.task', 'Download task completed',
          metadata: {'task_id': task.taskId, 'book_name': task.bookName, 'success': successCount});
    }

    await NotificationService.showDownloadComplete(
      id: notificationId,
      title: task.bookName,
      successCount: successCount,
      failCount: failCount,
      skipCount: skipCount,
    );

    _completionController.add(task.taskId);
  }

  void dispose() {
    _completionController.close();
  }

  static Future<void> resetInterruptedTasks(String dbPath) async {
    try {
      final json = await rust_api.getDownloadTasks(dbPath: dbPath);
      final List<dynamic> tasks = jsonDecode(json);
      for (final task in tasks) {
        if (task is Map<String, dynamic> &&
            task['status'] == DownloadTaskStatus.running) {
          await rust_api.updateDownloadTaskStatus(
            dbPath: dbPath,
            taskId: task['id'] as String,
            status: DownloadTaskStatus.failed,
            errorMessage: '应用意外关闭，下载中断',
          );
        }
      }
    } catch (e) {
      debugPrint('[Download] resetInterruptedTasks failed: $e');
    }
  }
}
