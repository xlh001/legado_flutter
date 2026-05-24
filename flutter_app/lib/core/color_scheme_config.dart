import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'persistence/json_store.dart';

/// How the primary / seed colour is sourced for the [ColorScheme].
enum ColorSource {
  /// Follow the device wallpaper via Android 12+ Monet (falls back to
  /// [preset] on unsupported platforms).
  dynamic_,

  /// Use one of the built-in preset seed colours.
  preset,
}

/// Persisted colour-configuration state.
final ColorSchemeConfig _defaultConfig = const ColorSchemeConfig(
  source: ColorSource.dynamic_,
  presetSeed: 0xFF006A4D,
);

/// Riverpod provider that loads the persisted colour config on first access
/// and notifies listeners on every change.
final colorSchemeConfigProvider =
    StateNotifierProvider<ColorSchemeConfigNotifier, ColorSchemeConfig>(
  (ref) => ColorSchemeConfigNotifier(),
);

class ColorSchemeConfig {
  final ColorSource source;
  final int presetSeed;

  const ColorSchemeConfig({
    required this.source,
    required this.presetSeed,
  });

  ColorSchemeConfig copyWith({ColorSource? source, int? presetSeed}) =>
      ColorSchemeConfig(
        source: source ?? this.source,
        presetSeed: presetSeed ?? this.presetSeed,
      );

  Map<String, dynamic> toJson() => {
        'source': source.name,
        'presetSeed': presetSeed,
      };

  factory ColorSchemeConfig.fromJson(Map<String, dynamic> json) {
    final sourceStr = json['source'] as String? ?? 'dynamic_';
    final source = ColorSource.values.firstWhere(
      (e) => e.name == sourceStr,
      orElse: () => ColorSource.dynamic_,
    );
    return ColorSchemeConfig(
      source: source,
      presetSeed: json['presetSeed'] as int? ?? _defaultConfig.presetSeed,
    );
  }
}

class ColorSchemeConfigNotifier extends StateNotifier<ColorSchemeConfig> {
  ColorSchemeConfigNotifier() : super(_defaultConfig) {
    _load();
  }

  static const _key = 'color_scheme_config';

  Future<void> _load() async {
    final map = await readJsonKey<Map?>(
      _key,
      (raw) => raw is Map ? raw : null,
      null,
    );
    if (map != null) {
      state = ColorSchemeConfig.fromJson(Map<String, dynamic>.from(map));
    }
  }

  Future<void> _save() async {
    await writeJsonKey(_key, state.toJson(), errorTag: 'color scheme config');
  }

  void setSource(ColorSource source) {
    state = state.copyWith(source: source);
    _save();
  }

  void setPresetSeed(int seed) {
    state = state.copyWith(source: ColorSource.preset, presetSeed: seed);
    _save();
  }
}

/// The 12 Material You tonal-palette preset colours (values are ARGB).
const presetSeedColors = <Color>[
  Color(0xFF006A4D), // Green (HTML design default)
  Color(0xFF00897B), // Teal
  Color(0xFF2E7D32), // Green
  Color(0xFF558B2F), // Light Green
  Color(0xFFF9A825), // Yellow
  Color(0xFFEF6C00), // Orange
  Color(0xFFD32F2F), // Red
  Color(0xFFC62828), // Deep Red
  Color(0xFFAD1457), // Pink
  Color(0xFF6A1B9A), // Purple
  Color(0xFF4527A0), // Deep Purple
  Color(0xFF37474F), // Blue Grey
];
