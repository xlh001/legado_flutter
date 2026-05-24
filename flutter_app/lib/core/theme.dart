import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color _defaultSeed = Color(0xFF006A4D);

  // ── Factory: build ThemeData from a ColorScheme ──────────────────

  /// Build a complete [ThemeData] from a [ColorScheme].
  ///
  /// The [colorScheme] can come from [ColorScheme.fromSeed] (preset mode)
  /// or [DynamicColorPlugin.getCorePalette] (Android 12+ Monet mode).
  static ThemeData build(ColorScheme colorScheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: _buildTextTheme(colorScheme.brightness),
      appBarTheme: _appBarTheme,
      bottomSheetTheme: _bottomSheetTheme,
      cardTheme: _cardTheme,
      checkboxTheme: _checkboxTheme,
      chipTheme: _chipTheme,
      dialogTheme: _dialogTheme,
      dividerTheme: _dividerTheme,
      dropdownMenuTheme: _dropdownMenuTheme,
      elevatedButtonTheme: _elevatedButtonTheme,
      filledButtonTheme: _filledButtonTheme,
      iconButtonTheme: _iconButtonTheme,
      inputDecorationTheme: _inputDecorationTheme,
      listTileTheme: _listTileTheme,
      navigationBarTheme: _navigationBarTheme,
      outlinedButtonTheme: _outlinedButtonTheme,
      popupMenuTheme: _popupMenuTheme,
      progressIndicatorTheme: _progressIndicatorTheme,
      radioTheme: _radioTheme,
      sliderTheme: _sliderTheme,
      snackBarTheme: _snackBarTheme,
      switchTheme: _switchTheme,
      tabBarTheme: _tabBarTheme,
      textButtonTheme: _textButtonTheme,
      tooltipTheme: _tooltipTheme,
      visualDensity: VisualDensity.standard,
    );
  }

  // ── Convenience: default light / dark (uses default seed) ───────

  static ThemeData get light =>
      build(ColorScheme.fromSeed(seedColor: _defaultSeed, brightness: Brightness.light));

  static ThemeData get dark =>
      build(ColorScheme.fromSeed(seedColor: _defaultSeed, brightness: Brightness.dark));

  // ── Shared component themes ─────────────────────────────────────

  static const _appBarTheme = AppBarTheme(
    centerTitle: true,
    elevation: 0,
    scrolledUnderElevation: 1,
  );

  static final _cardTheme = CardThemeData(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    clipBehavior: Clip.antiAlias,
  );

  static final _navigationBarTheme = NavigationBarThemeData(
    elevation: 2,
    indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  );

  static final _dialogTheme = DialogThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    elevation: 6,
    titleTextStyle: const TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
    ),
  );

  static final _bottomSheetTheme = BottomSheetThemeData(
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    clipBehavior: Clip.antiAlias,
  );

  static final _snackBarTheme = const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
  );

  static final _inputDecorationTheme = InputDecorationTheme(
    filled: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  );

  static final _chipTheme = ChipThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
  );

  static final _listTileTheme = ListTileThemeData(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );

  static final _dividerTheme = DividerThemeData(
    space: 0,
    thickness: 0.5,
  );

  static final _switchTheme = SwitchThemeData(
    trackOutlineWidth: WidgetStateProperty.all(0),
  );

  static final _radioTheme = RadioThemeData(
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) return null;
      return null;
    }),
  );

  static final _checkboxTheme = CheckboxThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  );

  static final _elevatedButtonTheme = ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static final _filledButtonTheme = FilledButtonThemeData(
    style: FilledButton.styleFrom(
      elevation: 0,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static final _outlinedButtonTheme = OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static final _textButtonTheme = TextButtonThemeData(
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static final _iconButtonTheme = IconButtonThemeData(
    style: IconButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  static final _popupMenuTheme = PopupMenuThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    elevation: 3,
  );

  static final _sliderTheme = SliderThemeData(
    trackHeight: 4,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
  );

  static final _tabBarTheme = TabBarThemeData(
    indicatorSize: TabBarIndicatorSize.tab,
    dividerHeight: 0,
  );

  static final _dropdownMenuTheme = DropdownMenuThemeData(
    menuStyle: MenuStyle(
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );

  static final _tooltipTheme = TooltipThemeData(
    decoration: BoxDecoration(
      color: Colors.grey.shade800,
      borderRadius: BorderRadius.circular(8),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    textStyle: const TextStyle(color: Colors.white, fontSize: 12),
  );

  static final _progressIndicatorTheme = ProgressIndicatorThemeData(
    linearMinHeight: 4,
    linearTrackColor: Colors.transparent,
  );

  // ── Helpers ─────────────────────────────────────────────────────

  /// Build a slightly customised [TextTheme] for consistent app typography.
  ///
  /// Uses MD3 defaults as the base; only adjusts a few key styles to keep
  /// the app feeling cohesive without diverging from the spec.
  static TextTheme _buildTextTheme(Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _defaultSeed,
        brightness: brightness,
      ),
    ).textTheme;

    return base.copyWith(
      // headings: moderate letter-spacing
      headlineMedium: base.headlineMedium,
      // body: standard reading sizes
      bodyLarge: base.bodyLarge,
      bodyMedium: base.bodyMedium,
      // labels: denser for buttons / chips / tabs
      labelLarge: base.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
