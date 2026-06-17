import 'package:flutter/material.dart';

class AppTheme {
  // Brand colours
  static const primary = Color(0xFF1565C0);
  static const primaryLight = Color(0xFF1976D2);
  static const primaryDark = Color(0xFF0D47A1);
  static const accent = Color(0xFF2979FF);

  static const success = Color(0xFF2E7D32);
  static const successLight = Color(0xFFE8F5E9);
  static const warning = Color(0xFFF57F17);
  static const warningLight = Color(0xFFFFFDE7);
  static const error = Color(0xFFC62828);
  static const errorLight = Color(0xFFFFEBEE);

  // Neutrals
  static const background = Color(0xFFF5F7FA);
  static const surface = Colors.white;
  static const border = Color(0xFFE0E0E0);
  static const textDark = Color(0xFF212121);
  static const textMedium = Color(0xFF616161);
  static const textLight = Color(0xFF9E9E9E);

  // Status colours for live map
  static const liveGreen = Color(0xFF2E7D32);
  static const staleOrange = Color(0xFFE65100);
  static const offlineGrey = Color(0xFF757575);

  // Shape
  static const radius = 12.0;
  static const radiusSm = 8.0;
  static const radiusXs = 6.0;

  // Shadows
  static List<BoxShadow> cardShadow = [
    BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 2)),
  ];

  static ThemeData get themeData => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.light),
        scaffoldBackgroundColor: background,
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: const BorderSide(color: border),
          ),
          color: surface,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusSm),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusSm),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusSm),
            borderSide: const BorderSide(color: primaryLight, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          labelStyle: const TextStyle(color: textMedium, fontSize: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: primaryLight,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          side: const BorderSide(color: border),
        ),
        dividerTheme: const DividerThemeData(color: border, space: 1),
        appBarTheme: const AppBarTheme(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
        ),
      );

  // Reusable stat card
  static Widget statChip({
    required IconData icon,
    required String label,
    required String value,
    Color? color,
  }) {
    final c = color ?? primaryLight;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withOpacity(0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c)),
          Text(label, style: const TextStyle(fontSize: 11, color: textMedium)),
        ],
      ),
    );
  }

  // Section header row
  static Widget sectionHeader(String title, {IconData? icon, Widget? trailing}) {
    return Row(
      children: [
        if (icon != null) ...[Icon(icon, size: 18, color: primaryLight), const SizedBox(width: 8)],
        Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: textDark))),
        if (trailing != null) trailing,
      ],
    );
  }
}
