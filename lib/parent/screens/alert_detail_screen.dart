// alert_detail_screen.dart — Individual Alert Detail with AI score, content preview, and actions
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:kova/core/app_mode.dart';
import 'package:kova/core/constants.dart';
import 'package:kova/local_backend/repositories/alert_repository.dart';
import 'package:kova/parent/services/app_control_service.dart';
import 'dart:math';

class AlertDetailScreen extends StatefulWidget {
  final AlertModel alert;

  const AlertDetailScreen({super.key, required this.alert});

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _entranceCtrl;
  late Animation<double> _bannerFade;
  late Animation<double> _detailsFade;
  late Animation<double> _previewFade;
  late Animation<double> _actionsFade;

  bool _contentUnlocked = false;
  late bool _isResolved;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _isResolved = widget.alert.resolved;
    _bannerFade = _fade(0.0, 0.3);
    _detailsFade = _fade(0.15, 0.5);
    _previewFade = _fade(0.3, 0.65);
    _actionsFade = _fade(0.5, 0.85);
    _entranceCtrl.forward();
  }

  Animation<double> _fade(double begin, double end) =>
      Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _entranceCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  void _showPinDialog() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _PinEntrySheet(),
    );

    if (result == true && mounted) {
      setState(() => _contentUnlocked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KovaColors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _entranceCtrl,
          builder: (context, _) {
            return Column(
              children: [
                // ── Header ──
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 16, top: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        color: KovaColors.textPrimary,
                        iconSize: 20,
                        onPressed: () => context.pop(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Back',
                        style: GoogleFonts.nunito(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: KovaColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Content ──
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: KovaSpacing.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),

                        // ── Alert banner ──
                        Opacity(
                          opacity: _bannerFade.value,
                          child: _buildAlertBanner(),
                        ),
                        const SizedBox(height: 8),

                        // ── App + time ──
                        Opacity(
                          opacity: _bannerFade.value,
                          child: Row(
                            children: [
                              Icon(
                                _getAppIcon(widget.alert.app),
                                size: 16,
                                color: KovaColors.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${_capitalize(widget.alert.app)} • ${_formatTime(widget.alert.createdAt)}',
                                style: GoogleFonts.nunito(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: KovaColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Detection details section ──
                        Opacity(
                          opacity: _detailsFade.value,
                          child: _buildDetectionDetails(),
                        ),
                        const SizedBox(height: 28),

                        // ── Content preview ──
                        Opacity(
                          opacity: _previewFade.value,
                          child: _buildContentPreview(),
                        ),
                        const SizedBox(height: 28),

                        // ── Automatic action taken ──
                        Opacity(
                          opacity: _actionsFade.value,
                          child: _buildAutomaticAction(),
                        ),
                        const SizedBox(height: 24),

                        // ── Action buttons ──
                        Opacity(
                          opacity: _actionsFade.value,
                          child: _buildActionButtons(),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════
  // ──  Alert Banner
  // ═══════════════════════════════════════════
  Widget _buildAlertBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: KovaColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KovaColors.danger.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: KovaColors.danger.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_rounded,
              color: KovaColors.danger,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Inappropriate\ncontent detected',
              style: GoogleFonts.nunito(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: KovaColors.danger,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════
  // ──  Detection Details
  // ═══════════════════════════════════════════
  Widget _buildDetectionDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Detection details',
              style: GoogleFonts.nunito(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: KovaColors.textPrimary,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: _getSeverityColor(widget.alert.severity).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.alert.severity.toUpperCase(),
                style: GoogleFonts.nunito(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _getSeverityColor(widget.alert.severity),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // AI Confidence circle + details
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: KovaColors.cardWhite,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: KovaColors.primary.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              // Circular score
              SizedBox(
                width: 72,
                height: 72,
                child: CustomPaint(
                  painter: _ScoreRingPainter(
                    score: widget.alert.scoreText,
                    color: _getSeverityColor(widget.alert.severity),
                    bgColor: _getSeverityColor(widget.alert.severity).withValues(alpha: 0.1),
                  ),
                  child: Center(
                    child: Text(
                      '${(widget.alert.scoreText * 100).round()}%',
                      style: GoogleFonts.nunito(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: _getSeverityColor(widget.alert.severity),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Confidence Score',
                      style: GoogleFonts.nunito(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: KovaColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'High probability of inappropriate content',
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: KovaColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Sender info
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: KovaColors.cardWhite,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Text(
                'Sender',
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: KovaColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '@unknown_user_2847',
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: KovaColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════
  // ──  Content Preview
  // ═══════════════════════════════════════════
  Widget _buildContentPreview() {
    // If unlocked, show actual content
    if (_contentUnlocked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Content preview',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: KovaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 14),

          // Actual content card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: KovaColors.cardWhite,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: KovaColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.visibility_rounded,
                      size: 20,
                      color: KovaColors.success,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Content unlocked',
                      style: GoogleFonts.nunito(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: KovaColors.success,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  widget.alert.contentPreview ?? 'No content preview available',
                  style: GoogleFonts.nunito(
                    fontSize: 14,
                    color: KovaColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Locked state - require PIN
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Content preview',
          style: GoogleFonts.nunito(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: KovaColors.textPrimary,
          ),
        ),
        const SizedBox(height: 14),

        // Preview icons row
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: KovaColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.visibility_off_rounded,
                size: 22,
                color: KovaColors.primary.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: KovaColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.play_circle_outline_rounded,
                size: 22,
                color: KovaColors.primary.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // View content button (PIN required)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _showPinDialog,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: KovaColors.primary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KovaRadius.pill),
              ),
            ),
            child: Text(
              'View content — PIN required',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: KovaColors.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════
  // ──  Automatic Action
  // ═══════════════════════════════════════════
  Widget _buildAutomaticAction() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: KovaColors.primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KovaColors.primary.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Automatic action taken',
            style: GoogleFonts.nunito(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: KovaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _isResolved
                ? '${_capitalize(widget.alert.app)} was blocked — resolved'
                : '${_capitalize(widget.alert.app)} automatically blocked — 20 min',
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: KovaColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════
  // ──  Action Buttons
  // ═══════════════════════════════════════════
  Widget _buildActionButtons() {
    return Column(
      children: [
        // Unblock now (only if blocked)
        if (!_isResolved)
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: () => _showActionPinDialog('unblock'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: KovaColors.textPrimary.withValues(alpha: 0.3),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(KovaRadius.pill),
                ),
              ),
              child: Text(
                'Unblock now',
                style: GoogleFonts.nunito(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: KovaColors.textPrimary,
                ),
              ),
            ),
          ),
        if (!_isResolved) const SizedBox(height: 10),

        // Block permanently
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: () => _showActionPinDialog('block'),
            style: ElevatedButton.styleFrom(
              backgroundColor: KovaColors.textPrimary,
              foregroundColor: KovaColors.textOnDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KovaRadius.pill),
              ),
              elevation: 0,
            ),
            child: Text(
              _isResolved ? 'Permanently blocked' : 'Block permanently',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),

        // Report false positive
        Center(
          child: TextButton.icon(
            onPressed: () {},
            icon: const Icon(
              Icons.flag_outlined,
              size: 16,
              color: KovaColors.textSecondary,
            ),
            label: Text(
              'Report false positive',
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: KovaColors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Helper methods
  Color _getSeverityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'critical':
      case 'high':
        return const Color(0xFFFF5252);
      case 'medium':
        return const Color(0xFFFB8C00);
      case 'low':
        return const Color(0xFF4AC38B);
      default:
        return const Color(0xFF4AC38B);
    }
  }

  IconData _getAppIcon(String appName) {
    switch (appName.toLowerCase()) {
      case 'whatsapp':
        return Icons.message_rounded;
      case 'instagram':
        return Icons.camera_alt_rounded;
      case 'tiktok':
        return Icons.music_note_rounded;
      case 'snapchat':
        return Icons.snapchat_rounded;
      case 'youtube':
        return Icons.play_circle_fill_rounded;
      case 'messenger':
        return Icons.chat_bubble_rounded;
      case 'facebook':
        return Icons.facebook_rounded;
      case 'twitter':
      case 'x':
        return Icons.chat_rounded;
      default:
        return Icons.apps_rounded;
    }
  }

  String _capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  String _formatTime(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  void _showActionPinDialog(String action) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _PinEntrySheet(),
    );

    if (result == true && mounted) {
      // PIN verified - perform action
      final service = AppControlService();
      if (action == 'block') {
        await service.blockApp(widget.alert.app);
      } else if (action == 'unblock') {
        await service.unblockApp(widget.alert.app);
      }
      
      // Update local DB to mark this alert as resolved
      await AlertRepository().resolve(widget.alert.id);
      
      setState(() {
        _isResolved = true;
      }); // Refresh UI
    }
  }
}

// ═══════════════════════════════════════════
// ──  Score Ring Painter
// ═══════════════════════════════════════════
class _ScoreRingPainter extends CustomPainter {
  final double score; // 0.0 – 1.0
  final Color color;
  final Color bgColor;

  _ScoreRingPainter({
    required this.score,
    required this.color,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;
    const strokeWidth = 6.0;

    // Background ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = bgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    // Score arc
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      2 * pi * score,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ScoreRingPainter oldDelegate) =>
      oldDelegate.score != score;
}

// ═══════════════════════════════════════════
// ──  PIN Entry Bottom Sheet
// ═══════════════════════════════════════════
class _PinEntrySheet extends StatefulWidget {
  const _PinEntrySheet();

  @override
  State<_PinEntrySheet> createState() => _PinEntrySheetState();
}

class _PinEntrySheetState extends State<_PinEntrySheet> {
  String _pin = '';
  static const int _pinLength = 4;
  bool _error = false;
  bool _verifying = false;

  void _onDigit(String digit) async {
    if (_pin.length < _pinLength && !_verifying) {
      setState(() {
        _pin += digit;
        _error = false;
      });

      if (_pin.length == _pinLength) {
        setState(() => _verifying = true);

        // Actual PIN verification
        final isValid = await AppModeManager.verifyPin(_pin);

        if (mounted) {
          if (isValid) {
            context.pop(true); // Return true for successful verification
          } else {
            setState(() {
              _pin = '';
              _error = true;
              _verifying = false;
            });
          }
        }
      }
    }
  }

  void _onBackspace() {
    if (_pin.isNotEmpty) {
      setState(() => _pin = _pin.substring(0, _pin.length - 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: KovaColors.cardWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: KovaColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Text(
            'Enter your PIN',
            style: GoogleFonts.nunito(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: KovaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 20),

          // PIN dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_pinLength, (i) {
              final isFilled = i < _pin.length;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isFilled ? (_error ? KovaColors.danger : KovaColors.primary) : Colors.transparent,
                  border: Border.all(
                    color: isFilled ? (_error ? KovaColors.danger : KovaColors.primary) : KovaColors.divider,
                    width: 2,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 12),

          // Error message
          if (_error)
            Text(
              'Incorrect PIN. Try again.',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: KovaColors.danger,
              ),
            )
          else if (_verifying)
            Text(
              'Verifying...',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: KovaColors.textSecondary,
              ),
            )
          else
            const SizedBox(height: 20),

          const SizedBox(height: 8),

          // Number pad
          _buildNumberPad(),
          const SizedBox(height: 12),

          // Cancel
          TextButton(
            onPressed: () => context.pop(),
            child: Text(
              'Cancel',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: KovaColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberPad() {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', '⌫'],
    ];

    return Column(
      children: rows.map((row) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map((key) {
              if (key.isEmpty) {
                return const SizedBox(width: 72, height: 56);
              }
              final isBackspace = key == '⌫';
              return GestureDetector(
                onTap: () {
                  if (isBackspace) {
                    _onBackspace();
                  } else {
                    _onDigit(key);
                  }
                },
                child: Container(
                  width: 72,
                  height: 56,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isBackspace
                        ? Colors.transparent
                        : KovaColors.background,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: isBackspace
                      ? const Icon(
                          Icons.backspace_outlined,
                          color: KovaColors.textSecondary,
                          size: 22,
                        )
                      : Text(
                          key,
                          style: GoogleFonts.nunito(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: KovaColors.textPrimary,
                          ),
                        ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
}
