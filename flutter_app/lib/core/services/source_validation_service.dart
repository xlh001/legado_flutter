import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api.dart' as rust_api;

/// 书源 Live Test 调用包装，via Riverpod provider 注入便于测试 fake。
///
/// BATCH-20 (F-W2B-020)：原 `source_page.dart` 顶部 module-level
/// `LiveTestRunner` typedef + `debugLiveTestRunnerOverride` global mutable
/// 全部移除。生产代码默认实现透传 [`rust_api.validateSourceLive`]，测试通过
/// `ProviderScope.overrides` 注入 fake 类即可。
class SourceValidationService {
  const SourceValidationService();

  /// 调 Rust 端 validate_source_live；返回 LiveTestReport JSON 字符串。
  Future<String> validateLive({
    required String dbPath,
    required String sourceId,
    required String keyword,
  }) {
    return rust_api.validateSourceLive(
      dbPath: dbPath,
      sourceId: sourceId,
      keyword: keyword,
    );
  }

  /// 批量校验书源。返回 `Vec<SourceCheckProgress>` 的 JSON 字符串。
  Future<String> batchCheckSources({
    required String dbPath,
    required String sourceIdsJson,
    required String configJson,
  }) {
    return rust_api.batchCheckSources(
      dbPath: dbPath,
      sourceIdsJson: sourceIdsJson,
      configJson: configJson,
    );
  }
}

final sourceValidationServiceProvider = Provider<SourceValidationService>(
  (ref) => const SourceValidationService(),
);
