import 'dart:ui';
import 'package:material_ui/material_ui.dart';

/// ЕДИНЫЙ ФАЙЛ ВСЕХ ЦВЕТОВ ПРИЛОЖЕНИЯ (меняешь здесь — меняется везде)
class GlassColors {
  static const brightness = Brightness.dark;

  // Основной цвет #096A95 и его оттенки
  static const accent = Color(0xFF096A95);
  static const accentBright = Color(0xFF12A3E2);
  static const accentLuminous = Color(0xFF36B8F2);
  static const accentHeroText = Color(0xFF7BCFF4);

  // Фон и свечение
  static const bgGradient = [
    Color(0xFF070D12),
    Color(0xFF0B1821),
    Color(0xFF0F212E),
  ];
  static const glowTopRight = Color.fromRGBO(9, 106, 149, 0.36);
  static const glowBottomLeft = Color.fromRGBO(18, 163, 226, 0.22);

  // Матовые стеклянные поверхности
  static const cardFill = Color.fromRGBO(255, 255, 255, 0.075);
  static const heroTint = Color.fromRGBO(9, 106, 149, 0.25);
  static const selectedTint = Color.fromRGBO(18, 163, 226, 0.20);
  static const cardBorder = Color.fromRGBO(255, 255, 255, 0.15);
  static const dockFill = Color.fromRGBO(10, 22, 32, 0.88);
  static const sheetBg = Color(0xFF0D1822);
  static const divider = Color.fromRGBO(255, 255, 255, 0.12);

  // Текст и статусы
  static const textPrimary = Color(0xFFF1F5F9);
  static const textSecondary = Color(0xFF94A3B8);
  static const positive = Color(0xFF4ADE80);
  static const negative = Color(0xFFF87171);
  static const successTint = Color.fromRGBO(34, 197, 94, 0.16);
  static const warningTint = Color.fromRGBO(245, 158, 11, 0.16);

  // График
  static const chartMedian = Color(0xFFFBBF24);
  static const chartGrid = Color.fromRGBO(255, 255, 255, 0.10);
  static const chartDotRing = Color(0xFF0C1A24);
}

class GlassBackground extends StatelessWidget {
  final Widget child;

  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: GlassColors.bgGradient,
              ),
            ),
          ),
        ),
        Positioned(
          top: -90,
          right: -70,
          child: IgnorePointer(
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    GlassColors.glowTopRight,
                    GlassColors.glowTopRight.withAlpha(0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -100,
          left: -80,
          child: IgnorePointer(
            child: Container(
              width: 340,
              height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    GlassColors.glowBottomLeft,
                    GlassColors.glowBottomLeft.withAlpha(0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blur;
  final bool useBlur;
  final Color? tintColor;
  final Color? borderColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 20,
    this.blur = 18,
    this.useBlur = true,
    this.tintColor,
    this.borderColor,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor ?? GlassColors.cardBorder,
          width: 1.0,
        ),
      ),
      padding: padding,
      child: child,
    );

    final materialBody = Material(
      color: tintColor ?? GlassColors.cardFill,
      child: (onTap != null || onLongPress != null)
          ? InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(borderRadius),
              child: content,
            )
          : content,
    );

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.35),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: useBlur
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: materialBody,
              )
            : materialBody,
      ),
    );
  }
}

class GlassCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const GlassCheckbox({
    super.key,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged != null ? () => onChanged!(!value) : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: value
                ? const LinearGradient(
                    colors: [GlassColors.accent, GlassColors.accentBright],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: value ? null : const Color.fromRGBO(255, 255, 255, 0.06),
            border: Border.all(
              color: value
                  ? GlassColors.accentLuminous
                  : const Color.fromRGBO(255, 255, 255, 0.28),
              width: 1.5,
            ),
            boxShadow: value
                ? [
                    BoxShadow(
                      color: GlassColors.accentBright.withAlpha(90),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: value
              ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

class GlassPillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool compact;

  const GlassPillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 14,
            vertical: compact ? 6 : 8,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: selected
                ? const LinearGradient(
                    colors: [GlassColors.accent, GlassColors.accentBright],
                  )
                : null,
            color: selected ? null : GlassColors.cardFill,
            border: Border.all(
              color: selected
                  ? GlassColors.accentLuminous
                  : GlassColors.cardBorder,
              width: 1.0,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: GlassColors.accent.withAlpha(110),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: selected ? Colors.white : GlassColors.textPrimary,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 12 : 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? Colors.white : GlassColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}