import 'dart:convert';
import 'dart:io';

import 'diagnostic_log_writer.dart';

class DiagnosticLogStats {
  final int fileCount;
  final int totalBytes;
  final DateTime? newestModified;

  const DiagnosticLogStats({
    required this.fileCount,
    required this.totalBytes,
    required this.newestModified,
  });
}

class DiagnosticLogReader {
  final Directory directory;

  const DiagnosticLogReader(this.directory);

  Future<List<String>> tail({int maxLines = 500}) async {
    final files = await _oldestFirstFiles();
    final lines = <String>[];
    for (final file in files) {
      if (!await file.exists()) continue;
      lines.addAll(await file.readAsLines());
      if (lines.length > maxLines) {
        lines.removeRange(0, lines.length - maxLines);
      }
    }
    return lines;
  }

  Future<File> exportMerged({required String outputPath}) async {
    final out = File(outputPath);
    await out.parent.create(recursive: true);
    final sink = out.openWrite();
    try {
      for (final file in await _oldestFirstFiles()) {
        if (!await file.exists()) continue;
        await for (final line in file.openRead().transform(utf8.decoder)) {
          sink.write(line);
        }
      }
    } finally {
      await sink.close();
    }
    return out;
  }

  Future<void> clear() async {
    await for (final file in DiagnosticLogWriter.logFiles(directory)) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<DiagnosticLogStats> stats() async {
    var count = 0;
    var bytes = 0;
    DateTime? newest;
    await for (final file in DiagnosticLogWriter.logFiles(directory)) {
      final stat = await file.stat();
      count++;
      bytes += stat.size;
      if (newest == null || stat.modified.isAfter(newest))
        newest = stat.modified;
    }
    return DiagnosticLogStats(
        fileCount: count, totalBytes: bytes, newestModified: newest);
  }

  Future<List<File>> _oldestFirstFiles() async {
    final files = await DiagnosticLogWriter.logFiles(directory).toList();
    return files.reversed.toList(growable: false);
  }
}
