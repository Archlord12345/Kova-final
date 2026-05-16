import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:kova/core/router.dart';

import '../services/accessibility_service.dart';
import 'package:permission_handler/permission_handler.dart';

/// Step-by-step permission setup screen.
/// Each service gets its own card with status indicator + Enable button.
/// When the user returns from system settings, KOVA auto-detects validation.
class AccessibilitySetupScreen extends StatefulWidget {
  const AccessibilitySetupScreen({super.key});

  @override
  State<AccessibilitySetupScreen> createState() =>
      _AccessibilitySetupScreenState();
}

class _AccessibilitySetupScreenState extends State<AccessibilitySetupScreen>
    with WidgetsBindingObserver {

  // ── Per-service status ──
  bool _accessibilityGranted = false;
  bool _notificationGranted = false;
  bool _keyboardGranted = false;
  bool _deviceAdminDone = false;
  bool _batteryOptimized = false;
  bool _autoStartDone = false;
  bool _protectionStarted = false;

  bool _isChecking = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAllStatuses();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User came back from system settings — re-check everything
      _checkAllStatuses();
    }
  }

  /// Check all service statuses and update the UI
  Future<void> _checkAllStatuses() async {
    if (_isChecking) return;
    _isChecking = true;

    try {
      final acc = await AccessibilityService.isAccessibilityPermissionGranted();
      final notif = await AccessibilityService.isNotificationListenerEnabled();
      final kbd = await AccessibilityService.isKeyboardEnabled();
      final battery = await Permission.ignoreBatteryOptimizations.isGranted;

      if (!mounted) return;

      final previousCompleted = _completedCount;

      setState(() {
        _accessibilityGranted = acc;
        _notificationGranted = notif;
        _keyboardGranted = kbd;
        _batteryOptimized = battery;
      });

      final newCompleted = _completedCount;

      // Show snackbar if a new service was just validated
      if (newCompleted > previousCompleted && previousCompleted >= 0) {
        final justValidated = _services[previousCompleted];
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${justValidated.title} enabled!',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF10B981),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.all(16),
            ),
          );

          // Scroll to the next pending service
          _scrollToNextPending();
        }
      }

      // If all required done, auto-start protection
      if (_allRequiredDone && !_protectionStarted) {
        await _startProtection();
      }
    } catch (e) {
      debugPrint('❌ Error checking statuses: $e');
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _startProtection() async {
    setState(() => _protectionStarted = true);
    await AccessibilityService.startProtectionService();
    await AccessibilityService.hideAppIcon();
  }

  /// Scroll to the next pending service card
  void _scrollToNextPending() {
    final nextIndex = _completedCount;
    if (nextIndex < _services.length && _scrollController.hasClients) {
      final offset = (nextIndex * 88.0).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ── Service definitions ──

  List<_ServiceInfo> get _services => [
    _ServiceInfo(
      title: 'Accessibility Service',
      description: 'Monitors app content to detect threats',
      icon: Icons.accessibility_new_rounded,
      isGranted: _accessibilityGranted,
      isRequired: true,
      instructions: [
        'Find "KOVA" in Downloaded apps',
        'Tap the switch to turn it ON',
        'Tap "Allow" to confirm',
      ],
      onRequest: () => AccessibilityService.requestAccessibilityPermission(),
    ),
    _ServiceInfo(
      title: 'Notification Listener',
      description: 'Reads incoming messages for safety analysis',
      icon: Icons.notifications_active_rounded,
      isGranted: _notificationGranted,
      isRequired: true,
      instructions: [
        'Find "KOVA" in the list',
        'Toggle the switch ON',
        'Press ← Back to return here',
      ],
      onRequest: () => AccessibilityService.requestNotificationListenerPermission(),
    ),
    _ServiceInfo(
      title: 'KOVA Keyboard',
      description: 'Detects outgoing harmful messages',
      icon: Icons.keyboard_rounded,
      isGranted: _keyboardGranted,
      isRequired: true,
      instructions: [
        'Enable "KOVA Keyboard" in input methods',
        'Select KOVA as your keyboard',
        'Press ← Back to return here',
      ],
      onRequest: () async {
        await AccessibilityService.requestKeyboardPermission();
        // After a short delay, show the picker to select it
        await Future.delayed(const Duration(seconds: 2));
        await AccessibilityService.showKeyboardPicker();
      },
    ),
    _ServiceInfo(
      title: 'Device Admin',
      description: 'Prevents unauthorized uninstallation',
      icon: Icons.admin_panel_settings_rounded,
      isGranted: _deviceAdminDone,
      isRequired: true,
      instructions: [
        'Tap "Activate" on the system prompt',
        'This prevents the child from uninstalling KOVA',
      ],
      onRequest: () async {
        await AccessibilityService.activateDeviceAdmin();
        // Mark as done after request (system prompt shown)
        if (mounted) setState(() => _deviceAdminDone = true);
      },
    ),
    _ServiceInfo(
      title: 'Battery Optimization',
      description: 'Keeps KOVA running in the background',
      icon: Icons.battery_saver_rounded,
      isGranted: _batteryOptimized,
      isRequired: false,
      instructions: [
        'Tap "Allow" to let KOVA run in background',
        'This ensures protection stays active',
      ],
      onRequest: () => Permission.ignoreBatteryOptimizations.request(),
    ),
    _ServiceInfo(
      title: 'Auto-Start',
      description: 'Restarts KOVA after phone reboot',
      icon: Icons.restart_alt_rounded,
      isGranted: _autoStartDone,
      isRequired: false,
      instructions: [
        'Enable auto-start for KOVA',
        'This setting varies by phone brand',
        'Press ← Back when done',
      ],
      onRequest: () async {
        final opened = await AccessibilityService.openAutoStartSettings();
        if (!opened && mounted) {
          // Some phones don't have this setting
          setState(() => _autoStartDone = true);
        } else {
          if (mounted) setState(() => _autoStartDone = true);
        }
      },
    ),
  ];

  int get _completedCount => _services.where((s) => s.isGranted).length;
  int get _totalCount => _services.length;
  bool get _allRequiredDone => _services.where((s) => s.isRequired).every((s) => s.isGranted);


  /// Navigate to dashboard
  void _continue() {
    if (_allRequiredDone) {
      context.go(AppRoutes.childDashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalCount > 0 ? _completedCount / _totalCount : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Column(
          children: [
            // ── Header with progress ──
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1C3D7A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.shield_rounded, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Configure Protection',
                              style: GoogleFonts.inter(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Step $_completedCount of $_totalCount completed',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Progress bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: const Color(0xFFE2E8F0),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _allRequiredDone
                            ? const Color(0xFF10B981)
                            : const Color(0xFF1C3D7A),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Service list ──
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                itemCount: _services.length,
                itemBuilder: (context, index) {
                  final service = _services[index];
                  final isNext = !service.isGranted &&
                      _services.take(index).every((s) => s.isGranted || !s.isRequired);

                  return _buildServiceCard(service, index, isNext);
                },
              ),
            ),

            // ── Bottom button ──
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SizedBox(
                width: double.infinity,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  child: ElevatedButton(
                    onPressed: _allRequiredDone ? _continue : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _allRequiredDone
                          ? const Color(0xFF10B981)
                          : const Color(0xFFCBD5E1),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _allRequiredDone ? Icons.check_circle_rounded : Icons.lock_rounded,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _allRequiredDone
                              ? 'Start Protection →'
                              : 'Complete all required steps',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServiceCard(_ServiceInfo service, int index, bool isNext) {
    final isGranted = service.isGranted;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
              color: isGranted
              ? const Color(0xFF10B981).withValues(alpha: 0.4)
              : isNext
                  ? const Color(0xFF1C3D7A).withValues(alpha: 0.4)
                  : const Color(0xFFE2E8F0),
          width: isNext ? 2 : 1,
        ),
        boxShadow: [
          if (isNext)
            BoxShadow(
              color: const Color(0xFF1C3D7A).withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Status icon
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isGranted
                      ? const Color(0xFF10B981).withValues(alpha: 0.12)
                      : isNext
                          ? const Color(0xFF1C3D7A).withValues(alpha: 0.1)
                          : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  isGranted ? Icons.check_circle_rounded : service.icon,
                  color: isGranted
                      ? const Color(0xFF10B981)
                      : isNext
                          ? const Color(0xFF1C3D7A)
                          : const Color(0xFF94A3B8),
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),

              // Title + description
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            service.title,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: isGranted
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        if (service.isRequired) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Required',
                              style: GoogleFonts.inter(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFFDC2626),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isGranted ? 'Enabled ✓' : service.description,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: isGranted
                            ? const Color(0xFF10B981).withValues(alpha: 0.8)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),

              // Action button
              if (!isGranted)
                SizedBox(
                  height: 36,
                  child: ElevatedButton(
                    onPressed: () => _showInstructionSheet(service),
                    style: ElevatedButton.styleFrom(
                      minimumSize: Size.zero,
                      backgroundColor: isNext
                          ? const Color(0xFF1C3D7A)
                          : const Color(0xFFF1F5F9),
                      foregroundColor: isNext ? Colors.white : const Color(0xFF64748B),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      'Enable',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              else
                const Icon(
                  Icons.verified_rounded,
                  color: Color(0xFF10B981),
                  size: 28,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Show instruction bottom sheet before opening system settings
  void _showInstructionSheet(_ServiceInfo service) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C3D7A).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(service.icon, color: const Color(0xFF1C3D7A), size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Enable ${service.title}',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Instructions
              ...service.instructions.asMap().entries.map((entry) {
                final step = entry.key + 1;
                final text = entry.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$step',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            text,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              color: const Color(0xFFCBD5E1),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),

              const SizedBox(height: 8),

              // Return reminder
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.arrow_back_rounded, color: Color(0xFFFBBF24), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Press the Back button to return to KOVA after enabling',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFFFDE68A),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Open settings button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    service.onRequest();
                  },
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    backgroundColor: const Color(0xFF1C3D7A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.open_in_new_rounded, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        'Open Settings',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Data class for each permission service
class _ServiceInfo {
  final String title;
  final String description;
  final IconData icon;
  final bool isGranted;
  final bool isRequired;
  final List<String> instructions;
  final Future<void> Function() onRequest;

  const _ServiceInfo({
    required this.title,
    required this.description,
    required this.icon,
    required this.isGranted,
    required this.isRequired,
    required this.instructions,
    required this.onRequest,
  });
}
