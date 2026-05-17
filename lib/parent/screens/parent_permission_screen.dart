import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:kova/core/constants.dart';
import 'package:kova/parent/services/parent_permission_service.dart';

/// Shown once on first launch of the parent app.
/// Each permission has its own "Grant" button and live status indicator.
/// The screen auto-refreshes status when the user returns from system settings.
class ParentPermissionScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const ParentPermissionScreen({super.key, required this.onComplete});

  @override
  State<ParentPermissionScreen> createState() => _ParentPermissionScreenState();
}

class _ParentPermissionScreenState extends State<ParentPermissionScreen>
    with WidgetsBindingObserver {

  // Permission status map — drives the UI
  Map<String, bool> _status = {
    'notifications': false,
    'nearbyWifi': false,
    'battery': false,
    'exactAlarm': false,
  };

  bool _loading = false;
  bool _checkingIndividual = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-check all statuses when app resumes (user returned from settings)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    debugPrint('🔄 [PERMISSIONS] Refreshing permission status...');
    final s = await ParentPermissionService.getStatus();
    debugPrint('📊 [PERMISSIONS] Status: notifications=${s['notifications']}, nearbyWifi=${s['nearbyWifi']}, battery=${s['battery']}, exactAlarm=${s['exactAlarm']}');
    
    if (!mounted) return;
    setState(() => _status = s);

    // Auto-advance if all required permissions are already granted
    final notificationsGranted = _status['notifications'] ?? false;
    final nearbyWifiGranted = _status['nearbyWifi'] ?? false;
    final allRequired = notificationsGranted;
    
    debugPrint('🔍 [PERMISSIONS] allRequired=$allRequired (notifications=$notificationsGranted, nearbyWifi=$nearbyWifiGranted)');
    
    if (allRequired) {
      debugPrint('✅ [PERMISSIONS] All required permissions granted - auto-advancing...');
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        debugPrint('🚀 [PERMISSIONS] Calling onComplete from auto-advance');
        widget.onComplete();
      }
    }
  }

  Future<void> _grantAll() async {
    setState(() => _loading = true);
    await ParentPermissionService.checkAndRequestAll(context);
    await _refresh();
    setState(() => _loading = false);
  }

  Future<void> _grantIndividual(String key) async {
    setState(() => _checkingIndividual = true);
    switch (key) {
      case 'notifications':
        await ParentPermissionService.requestNotifications();
      case 'nearbyWifi':
        await ParentPermissionService.requestNearbyWifi();
      case 'battery':
        await ParentPermissionService.requestBatteryOptimization();
      case 'exactAlarm':
        await ParentPermissionService.requestExactAlarm();
    }
    await _refresh();
    setState(() => _checkingIndividual = false);
  }

  bool get _allRequiredGranted =>
      (_status['notifications'] ?? false);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KovaColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 8),

              // ── Header Icon ──────────────────────────────────────────
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: KovaColors.primary.withValues(alpha: 0.06),
                ),
                child: Center(
                  child: Icon(
                    Icons.admin_panel_settings_outlined,
                    size: 40,
                    color: KovaColors.primary.withValues(alpha: 0.75),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Text(
                'Set Up KOVA Parent',
                style: GoogleFonts.nunito(
                  color: KovaColors.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Subtitle
              Text(
                'Grant these permissions so KOVA can alert you\nin real time when your child needs help.',
                style: GoogleFonts.nunito(
                  color: KovaColors.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Status badge
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _allRequiredGranted
                    ? _buildAllGrantedBadge()
                    : _buildPendingBadge(),
              ),

              const SizedBox(height: 28),

              // ── Permission Cards ──────────────────────────────────────
              _PermissionItem(
                icon: Icons.notifications_active_outlined,
                title: 'Notifications',
                description: 'Receive instant alerts when a threat is detected.',
                required: true,
                granted: _status['notifications'] ?? false,
                onGrant: _checkingIndividual ? null : () => _grantIndividual('notifications'),
              ),
              const SizedBox(height: 12),
              _PermissionItem(
                icon: Icons.wifi_find_outlined,
                title: 'Nearby Wi-Fi Devices',
                description:
                    'Discover the child device on your local network (LAN). '
                    'Without this, KOVA falls back to a slower internet relay.',
                required: false, // Made optional because some Android OS versions hide it
                granted: _status['nearbyWifi'] ?? false,
                onGrant: _checkingIndividual ? null : () => _grantIndividual('nearbyWifi'),
              ),
              const SizedBox(height: 12),
              _PermissionItem(
                icon: Icons.battery_saver_outlined,
                title: 'Battery — No Restrictions',
                description:
                    'Keep receiving alerts even when your screen is off. '
                    'Critical on Xiaomi/MIUI and Samsung.',
                required: false,
                granted: _status['battery'] ?? false,
                onGrant: _checkingIndividual ? null : () => _grantIndividual('battery'),
              ),
              const SizedBox(height: 12),
              _PermissionItem(
                icon: Icons.alarm_outlined,
                title: 'Exact Alarms',
                description: 'Used for reliable background watchdog scheduling.',
                required: false,
                granted: _status['exactAlarm'] ?? false,
                onGrant: _checkingIndividual ? null : () => _grantIndividual('exactAlarm'),
              ),

              const SizedBox(height: 32),

              // ── Grant All Button ──────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _grantAll,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KovaColors.primary,
                    disabledBackgroundColor: KovaColors.primary.withValues(alpha: 0.5),
                    foregroundColor: KovaColors.textOnDark,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(KovaRadius.pill),
                    ),
                    elevation: 0,
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Text(
                          'Grant All Permissions',
                          style: GoogleFonts.nunito(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),

              // Continue button — only shown when required permissions granted
              if (_allRequiredGranted) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () {
                      debugPrint('✅ [PERMISSIONS] Continue button pressed - calling onComplete');
                      if (mounted) {
                        widget.onComplete();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KovaColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(KovaRadius.pill),
                      ),
                      elevation: 2,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Continue',
                          style: GoogleFonts.nunito(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_forward_rounded,
                            color: Colors.white, size: 20),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: widget.onComplete,
                  child: Text(
                    'Skip for now (not recommended)',
                    style: GoogleFonts.nunito(
                      color: KovaColors.textSecondary.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAllGrantedBadge() {
    return Container(
      key: const ValueKey('all_granted'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: KovaColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(KovaRadius.pill),
        border: Border.all(color: KovaColors.success.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_rounded,
              color: KovaColors.success, size: 16),
          const SizedBox(width: 6),
          Text(
            'All required permissions granted',
            style: GoogleFonts.nunito(
              color: KovaColors.success,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingBadge() {
    final pending = [
      if (!(_status['notifications'] ?? false)) 'Notifications',
      if (!(_status['nearbyWifi'] ?? false)) 'Nearby Wi-Fi',
    ].join(', ');
    return Container(
      key: const ValueKey('pending'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: KovaColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(KovaRadius.pill),
        border: Border.all(color: KovaColors.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: KovaColors.accent, size: 16),
          const SizedBox(width: 6),
          Text(
            'Required: $pending',
            style: GoogleFonts.nunito(
              color: KovaColors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Individual permission row widget
// ────────────────────────────────────────────────────────────────────────────

class _PermissionItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool required;
  final bool granted;
  final VoidCallback? onGrant;

  const _PermissionItem({
    required this.icon,
    required this.title,
    required this.description,
    required this.required,
    required this.granted,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = granted
        ? KovaColors.success.withValues(alpha: 0.3)
        : required
            ? KovaColors.primary.withValues(alpha: 0.2)
            : KovaColors.divider;

    final bgColor = granted
        ? KovaColors.success.withValues(alpha: 0.03)
        : KovaColors.cardWhite;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(KovaRadius.card),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: granted
                  ? KovaColors.success.withValues(alpha: 0.08)
                  : KovaColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Icon(
                icon,
                size: 22,
                color: granted
                    ? KovaColors.success
                    : KovaColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 14),

          // Text content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: GoogleFonts.nunito(
                          color: KovaColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (required && !granted)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: KovaColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Required',
                          style: GoogleFonts.nunito(
                            color: KovaColors.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: GoogleFonts.nunito(
                    color: KovaColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Status / Grant button
          if (granted)
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: KovaColors.success.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: KovaColors.success, size: 24),
            )
          else
            GestureDetector(
              onTap: onGrant,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: onGrant != null
                      ? KovaColors.primary
                      : KovaColors.divider,
                  borderRadius: BorderRadius.circular(KovaRadius.button),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 14,
                      color: onGrant != null
                          ? KovaColors.textOnDark
                          : KovaColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Grant',
                      style: GoogleFonts.nunito(
                        color: onGrant != null
                            ? KovaColors.textOnDark
                            : KovaColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
