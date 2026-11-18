import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'screens/home_screen.dart';
import 'widgets/glass_ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const PocketReceiptApp());
}

class PocketReceiptApp extends StatelessWidget {
  const PocketReceiptApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Карманный чек',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: GlassColors.brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: GlassColors.accent,
          brightness: GlassColors.brightness,
          surface: GlassColors.sheetBg,
        ),
        scaffoldBackgroundColor: GlassColors.bgGradient.first,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: GlassColors.textPrimary,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: GlassColors.textPrimary,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: GlassColors.accent,
            foregroundColor: Colors.white,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: GlassColors.accentHeroText,
            side: const BorderSide(color: GlassColors.cardBorder),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: GlassColors.cardFill,
          labelStyle: const TextStyle(color: GlassColors.textSecondary),
          hintStyle: const TextStyle(color: GlassColors.textSecondary),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: GlassColors.cardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: GlassColors.cardBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
              color: GlassColors.accentLuminous,
              width: 1.5,
            ),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}