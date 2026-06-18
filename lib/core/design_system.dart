import 'dart:ui';
import 'package:flutter/material.dart';
import 'app_theme.dart';

/// ATOMS: Premium Glow Text with custom shadows
class GlowText extends StatelessWidget {
  const GlowText(
    this.text, {
    super.key,
    required this.style,
    required this.glowColor,
    this.glowRadius = 8.0,
    this.textAlign,
  });

  final String text;
  final TextStyle style;
  final Color glowColor;
  final double glowRadius;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: textAlign,
      style: style.copyWith(
        shadows: [
          Shadow(
            color: glowColor.withValues(alpha: 0.6),
            blurRadius: glowRadius,
          ),
          Shadow(
            color: glowColor.withValues(alpha: 0.3),
            blurRadius: glowRadius * 2.0,
          ),
        ],
      ),
    );
  }
}

/// ATOMS: Liquid Glass Card Container with reflective borders and backdrops
class LiquidGlassContainer extends StatelessWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 24.0,
    this.padding = const EdgeInsets.all(16.0),
    this.blurSigma = 16.0,
    this.accentColor,
    this.borderWidth = 1.5,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final double blurSigma;
  final Color? accentColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final activeColor = accentColor ?? AppTheme.accent;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.08),
                Colors.white.withValues(alpha: 0.02),
              ],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.09),
              width: borderWidth,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: -2,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: activeColor.withValues(alpha: 0.05),
                blurRadius: 16,
                spreadRadius: -4,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// ATOMS: Neo Glass Button with spring scale animations and glowing states
class NeoGlassButton extends StatefulWidget {
  const NeoGlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.accentColor,
    this.height = 54.0,
    this.borderRadius = 16.0,
    this.glowing = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Color? accentColor;
  final double height;
  final double borderRadius;
  final bool glowing;

  @override
  State<NeoGlassButton> createState() => _NeoGlassButtonState();
}

class _NeoGlassButtonState extends State<NeoGlassButton>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    if (widget.glowing) {
      _glowController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant NeoGlassButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.glowing != oldWidget.glowing) {
      if (widget.glowing) {
        _glowController.repeat(reverse: true);
      } else {
        _glowController.stop();
      }
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.accentColor ?? AppTheme.accent;
    final isEnabled = widget.onPressed != null;

    return GestureDetector(
      onTapDown: isEnabled ? (_) => setState(() => _isPressed = true) : null,
      onTapUp: isEnabled ? (_) => setState(() => _isPressed = false) : null,
      onTapCancel: isEnabled ? () => setState(() => _isPressed = false) : null,
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _isPressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedBuilder(
          animation: _glowController,
          builder: (context, child) {
            final double glowValue = widget.glowing ? _glowController.value : 0.0;
            return Container(
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                gradient: LinearGradient(
                  colors: isEnabled
                      ? [
                          activeColor.withValues(alpha: 0.15 + glowValue * 0.05),
                          activeColor.withValues(alpha: 0.03 + glowValue * 0.02),
                        ]
                      : [
                          Colors.white.withValues(alpha: 0.04),
                          Colors.white.withValues(alpha: 0.01),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: isEnabled
                      ? activeColor.withValues(alpha: 0.35 + glowValue * 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  width: 1.5,
                ),
                boxShadow: isEnabled
                    ? [
                        BoxShadow(
                          color: activeColor.withValues(alpha: 0.15 + glowValue * 0.1),
                          blurRadius: 12 + glowValue * 6,
                          spreadRadius: -1,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Center(child: widget.child),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// MOLECULES: Custom Sliding Segmented Tab Bar Selector
class GlassSegmentedControl<T> extends StatelessWidget {
  const GlassSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedSegment,
    required this.onSegmentSelected,
    this.height = 50.0,
  });

  final Map<T, String> segments;
  final T selectedSegment;
  final ValueChanged<T> onSegmentSelected;
  final double height;

  @override
  Widget build(BuildContext context) {
    final keys = segments.keys.toList();
    return Container(
      height: height,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
          width: 1,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = (constraints.maxWidth - 8) / keys.length;
          final selectedIndex = keys.indexOf(selectedSegment);

          return Stack(
            children: [
              // Sliding active indicator
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOutCubic,
                left: selectedIndex * tabWidth,
                width: tabWidth,
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [
                        Colors.white24,
                        Colors.white10,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
              // Buttons
              Row(
                children: keys.map((key) {
                  final isSelected = selectedSegment == key;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => onSegmentSelected(key),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(
                          segments[key]!,
                          style: AppTheme.bodyLarge.copyWith(
                            fontSize: 13,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          );
        },
      ),
    );
  }
}
