import 'package:flutter/material.dart';

/// Wählbare Designs.
enum AppDesign {
  system('System'),
  light('Hell'),
  dark('Dunkel'),
  graphite('Graphit');

  const AppDesign(this.label);
  final String label;
}

/// Akzentfarbe von „Graphit“.
const graphiteCopper = Color(0xFFD9A35B);

/// Standard-Design (Material 3 aus einer Grundfarbe).
ThemeData standardTheme(Brightness b) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF2E7D6B),
    brightness: b,
  ),
  useMaterial3: true,
);

/// „Graphit“: fast schwarz, warme Grautöne, Kupfer als Akzent, flache
/// Formen. Bewusst kein automatisch erzeugtes Farbschema und keine
/// Pastell-Flächen.
ThemeData graphiteTheme() {
  const bg = Color(0xFF111214);
  const surface = Color(0xFF16171A);
  const ink = Color(0xFFE7E3DC); // warmes Weiß
  const muted = Color(0xFF9D978D);
  const copper = graphiteCopper;
  const line = Color(0xFF2B2D31);
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: copper,
    onPrimary: Color(0xFF1C1407),
    primaryContainer: Color(0xFF3B2C17),
    onPrimaryContainer: Color(0xFFF3D6AC),
    secondary: Color(0xFFB4ADA2),
    onSecondary: Color(0xFF1B1A18),
    secondaryContainer: Color(0xFF26282C),
    onSecondaryContainer: Color(0xFFCFC8BD),
    tertiary: Color(0xFF8FB0C4),
    onTertiary: Color(0xFF0E1A22),
    tertiaryContainer: Color(0xFF1F2E38),
    onTertiaryContainer: Color(0xFFC9DDEA),
    error: Color(0xFFE5776E),
    onError: Color(0xFF2A0B08),
    errorContainer: Color(0xFF4A1F1B),
    onErrorContainer: Color(0xFFFAD3CE),
    surface: surface,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceDim: bg,
    surfaceBright: Color(0xFF2E3136),
    surfaceContainerLowest: bg,
    surfaceContainerLow: Color(0xFF191A1D),
    surfaceContainer: Color(0xFF1D1F22),
    surfaceContainerHigh: Color(0xFF232529),
    surfaceContainerHighest: Color(0xFF2A2D31),
    outline: Color(0xFF45484D),
    outlineVariant: line,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: ink,
    onInverseSurface: Color(0xFF1B1C1E),
    inversePrimary: Color(0xFF7A5420),
    surfaceTint: Colors.transparent, // keine Einfärbung erhöhter Flächen
  );
  final r8 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final r6 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: Brightness.dark,
  );
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    splashFactory: InkRipple.splashFactory, // ruhiger als das M3-Funkeln
    dividerTheme: const DividerThemeData(color: line, space: 1, thickness: 1),
    textTheme: base.textTheme
        .apply(bodyColor: ink, displayColor: ink)
        .copyWith(
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: ink,
          ),
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
            color: ink,
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: bg,
      indicatorColor: copper.withValues(alpha: 0.14),
      indicatorShape: r8,
      selectedIconTheme: const IconThemeData(color: copper),
      unselectedIconTheme: const IconThemeData(color: muted),
      selectedLabelTextStyle: const TextStyle(color: copper, fontSize: 12),
      unselectedLabelTextStyle: const TextStyle(color: muted, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: copper.withValues(alpha: 0.14),
      indicatorShape: r8,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? copper : muted,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF1A1B1E),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF1C1D20),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: line),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF1C1D20),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFF202226),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: r8),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: r8,
        side: const BorderSide(color: Color(0xFF3A3D42)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: r8),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: r6,
        side: const BorderSide(color: Color(0xFF3A3D42)),
        foregroundColor: const Color(0xFFCFC8BD),
        selectedBackgroundColor: copper.withValues(alpha: 0.18),
        selectedForegroundColor: copper,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: r6,
      side: const BorderSide(color: Color(0xFF3A3D42)),
      backgroundColor: surface,
      selectedColor: copper.withValues(alpha: 0.18),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Color(0xFF1B1C1F),
    ),
    searchBarTheme: SearchBarThemeData(
      backgroundColor: const WidgetStatePropertyAll(Color(0xFF1B1C1F)),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: line),
        ),
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      trackHeight: 3,
      activeTrackColor: copper,
      inactiveTrackColor: const Color(0xFF34373C),
      thumbColor: const Color(0xFFF0E6D6),
      overlayColor: copper.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      year2023: true, // klassischer Regler statt M3-Balken mit Lücke
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: copper,
      linearTrackColor: Color(0xFF2A2C30),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? const Color(0xFF1C1407) : muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? copper : const Color(0xFF2A2C30),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Color(0xFF3A3D42)),
    ),
    listTileTheme: const ListTileThemeData(iconColor: muted),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF2A2D31),
      contentTextStyle: TextStyle(color: ink),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF2E3136),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: ink, fontSize: 12),
    ),
  );
}
