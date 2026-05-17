import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:kova/core/constants.dart';
import 'package:kova/core/router.dart';
import 'package:kova/local_backend/repositories/child_repository.dart';
import 'package:kova/shared/services/network_sync_service.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

class WhatsappConnectScreen extends StatefulWidget {
  const WhatsappConnectScreen({super.key});

  @override
  State<WhatsappConnectScreen> createState() => _WhatsappConnectScreenState();
}

class _WhatsappConnectScreenState extends State<WhatsappConnectScreen>
    with TickerProviderStateMixin {
  // 0 = QR Code tab, 1 = Pairing Code tab
  int _activeTab = 0;
  bool _isConnected = false;
  String _pairingCode = '';

  final _childRepo = ChildRepository();
  bool _isDisposed = false;
  StreamSubscription? _pairingSub;

  // ── Entrance animations ──
  late AnimationController _entranceCtrl;
  late Animation<double> _titleFade;
  late Animation<Offset> _titleSlide;
  late Animation<double> _tabsFade;
  late Animation<Offset> _tabsSlide;
  late Animation<double> _contentFade;
  late Animation<Offset> _contentSlide;
  late Animation<double> _stepsFade;
  late Animation<Offset> _stepsSlide;
  late Animation<double> _bottomFade;
  late Animation<Offset> _bottomSlide;

  // ── QR scan line animation ──
  late AnimationController _scanLineCtrl;
  late Animation<double> _scanLinePosition;

  // ── Pulse animation for waiting status ──
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseOpacity;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _loadPairingCode();
    _entranceCtrl.forward();

    // Subscribe to reactive pairing complete stream
    // This fires instantly when LAN pairing succeeds, avoiding poll delays
    _pairingSub = NetworkSyncService.instance.onPairingComplete.listen((data) {
      if (!_isDisposed && mounted && !_isConnected) {
        setState(() => _isConnected = true);
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (!_isDisposed && mounted) {
            context.go(AppRoutes.parentSuccess);
          }
        });
      }
    });
  }



  void _initAnimations() {
    // ── Entrance staggered ──
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _titleFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.0, 0.3, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: const Interval(0.0, 0.3, curve: Curves.easeOutCubic),
          ),
        );

    _tabsFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.15, 0.45, curve: Curves.easeOut),
      ),
    );
    _tabsSlide = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: const Interval(0.15, 0.45, curve: Curves.easeOutCubic),
          ),
        );

    _contentFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.3, 0.65, curve: Curves.easeOut),
      ),
    );
    _contentSlide =
        Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: const Interval(0.3, 0.65, curve: Curves.easeOutCubic),
          ),
        );

    _stepsFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.5, 0.8, curve: Curves.easeOut),
      ),
    );
    _stepsSlide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: const Interval(0.5, 0.8, curve: Curves.easeOutCubic),
          ),
        );

    _bottomFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.7, 1.0, curve: Curves.easeOut),
      ),
    );
    _bottomSlide = Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _entranceCtrl,
            curve: const Interval(0.7, 1.0, curve: Curves.easeOutCubic),
          ),
        );

    // ── QR scan line ──
    _scanLineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _scanLinePosition = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _scanLineCtrl, curve: Curves.easeInOut));

    // ── Pulse for waiting ──
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseOpacity = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pairingSub?.cancel();
    _entranceCtrl.dispose();
    _scanLineCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  /// Assign a random code from the pre-registered pool and register with Railway
  Future<void> _loadPairingCode() async {
    final children = await _childRepo.getAll();
    String childId;
    final childName = LocalStorage.getString('child_name');
    final nameToUse = childName.isNotEmpty ? childName : 'Child';

    if (children.isNotEmpty) {
      childId = children.first.id;
      await _childRepo.updateName(childId, nameToUse);
    } else {
      childId = await _childRepo.create(nameToUse);
    }

    // Ensure parent has a device ID
    var deviceId = LocalStorage.getString('device_id');
    if (deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await LocalStorage.setString('device_id', deviceId);
    }

    // Pick a random unused code from the DB pool
    final code = await _childRepo.assignPairingCode(childId);
    if (!mounted) return;
    setState(() => _pairingCode = code);

    // Register with Railway relay
    final networkSync = NetworkSyncService();
    await networkSync.start(role: 'parent'); // Start offline discovery
    final registered = await networkSync.registerPairingCode(code);
    
    if (registered) {
      _startPolling(code);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to register code online. Please check network.', style: TextStyle(color: Colors.white)),
            backgroundColor: KovaColors.danger,
          ),
        );
      }
    }
  }

  void _startPolling(String code) async {
    if (_isDisposed || _isConnected) return;
    
    final networkSync = NetworkSyncService();
    // Poll Railway for claim status
    final token = await networkSync.checkPairingStatus(code);
    
    if (token != null) {
      // Child successfully claimed the code!
      // (networkSync already started)

      // Push child profile to relay so child side can sync the name
      final children = await _childRepo.getAll();
      if (children.isNotEmpty) {
        final child = children.first;
        await networkSync.pushChildProfile(
          childId: child.id,
          name: child.name,
          age: child.age,
        );
      }
      
      if (!_isDisposed && mounted) {
        setState(() {
          _isConnected = true;
        });
        
        // Auto-navigate after success
        await Future.delayed(const Duration(milliseconds: 1500));
        if (!_isDisposed && mounted) {
          context.go(AppRoutes.parentSuccess);
        }
      }
    } else {
      // Continue polling
      await Future.delayed(const Duration(seconds: 3));
      if (!_isDisposed && mounted) {
        _startPolling(code);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KovaColors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _entranceCtrl,
            _scanLineCtrl,
            _pulseCtrl,
          ]),
          builder: (context, _) {
            return Column(
              children: [
                // ── Back button ──
                Padding(
                  padding: const EdgeInsets.only(
                    left: 8,
                    right: KovaSpacing.lg,
                    top: 8,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        color: KovaColors.textPrimary,
                        iconSize: 20,
                        onPressed: () => context.pop(),
                      ),
                    ],
                  ),
                ),

                // ── Scrollable content ──
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: KovaSpacing.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),

                        // ── Title + subtitle ──
                        SlideTransition(
                          position: _titleSlide,
                          child: Opacity(
                            opacity: _titleFade.value,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Connect with Child',
                                  style: GoogleFonts.nunito(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: KovaColors.primary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Choose your preferred connection method',
                                  style: GoogleFonts.nunito(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: KovaColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Tab toggle ──
                        SlideTransition(
                          position: _tabsSlide,
                          child: Opacity(
                            opacity: _tabsFade.value,
                            child: _buildTabToggle(),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Content area (QR or Pairing) ──
                        SlideTransition(
                          position: _contentSlide,
                          child: Opacity(
                            opacity: _contentFade.value,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 350),
                              switchInCurve: Curves.easeOut,
                              switchOutCurve: Curves.easeIn,
                              child: _activeTab == 0
                                  ? _buildQRContent(key: const ValueKey('qr'))
                                  : _buildPairingContent(
                                      key: const ValueKey('pairing'),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Steps ──
                        SlideTransition(
                          position: _stepsSlide,
                          child: Opacity(
                            opacity: _stepsFade.value,
                            child: _buildSteps(),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Status ──
                        SlideTransition(
                          position: _bottomSlide,
                          child: Opacity(
                            opacity: _bottomFade.value,
                            child: Column(
                              children: [
                                _buildStatusPill(),
                                const SizedBox(height: 20),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
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
  // ──  Tab Toggle
  // ═══════════════════════════════════════════
  Widget _buildTabToggle() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KovaColors.divider),
        color: KovaColors.cardWhite,
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _buildTabButton(0, Icons.qr_code_rounded, 'Scan QR code'),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _buildTabButton(1, Icons.tag_rounded, 'Use pairing code'),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(int index, IconData icon, String label) {
    final isActive = _activeTab == index;
    return GestureDetector(
      onTap: () => setState(() => _activeTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isActive ? KovaColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isActive
                  ? KovaColors.textOnDark
                  : KovaColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isActive
                    ? KovaColors.textOnDark
                    : KovaColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════
  // ──  QR Code Content
  // ═══════════════════════════════════════════
  Widget _buildQRContent({Key? key}) {
    return Center(
      key: key,
      child: Container(
        width: 200,
        height: 200,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KovaColors.cardWhite,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: KovaColors.primary.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            // QR Code
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: QrImageView(
                data: 'kova://pair/$_pairingCode',
                version: QrVersions.auto,
                size: 168,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF1B2B6B),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF1B2B6B),
                ),
                backgroundColor: Colors.white,
              ),
            ),

            // Animated scan line (only when not connected)
            if (!_isConnected)
              Positioned(
                top: _scanLinePosition.value * 160,
                left: 0,
                right: 0,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        KovaColors.success.withValues(alpha: 0.7),
                        KovaColors.success,
                        KovaColors.success.withValues(alpha: 0.7),
                        Colors.transparent,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: KovaColors.success.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),

            // Success overlay
            if (_isConnected)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: KovaColors.cardWhite.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.check_circle_rounded,
                      color: KovaColors.success,
                      size: 64,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════
  // ──  Pairing Code Content
  // ═══════════════════════════════════════════
  Widget _buildPairingContent({Key? key}) {
    return Center(
      key: key,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        decoration: BoxDecoration(
          color: KovaColors.primary.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KovaColors.primary.withValues(alpha: 0.12)),
        ),
        child: Column(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.95, end: 1.0),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack,
              builder: (context, scale, child) {
                return Transform.scale(scale: scale, child: child);
              },
              child: Text(
                _pairingCode,
                style: GoogleFonts.nunito(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: KovaColors.primary,
                  letterSpacing: 2.5,
                ),
              ),
            ),
            const SizedBox(height: 14),
            // Copy button
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _pairingCode));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Code copied!',
                      style: GoogleFonts.nunito(fontWeight: FontWeight.w600),
                    ),
                    backgroundColor: KovaColors.primary,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.copy_rounded,
                    size: 14,
                    color: KovaColors.primary.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Tap to copy',
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: KovaColors.primary.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════
  // ──  Steps
  // ═══════════════════════════════════════════
  Widget _buildSteps() {
    final steps = _activeTab == 0
        ? [
            'Open Kova on your child\'s phone',
            'Go to Settings → Pair with Parent',
            'Scan this QR code',
          ]
        : [
            'Open Kova on your child\'s phone',
            'Go to Settings → Pair with Parent',
            'Enter the pairing code above',
          ];

    return Column(
      children: List.generate(steps.length, (i) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: KovaColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${i + 1}',
                  style: GoogleFonts.nunito(
                    color: KovaColors.textOnDark,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    steps[i],
                    style: GoogleFonts.nunito(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: KovaColors.textPrimary,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  // ═══════════════════════════════════════════
  // ──  Status Pill
  // ═══════════════════════════════════════════
  Widget _buildStatusPill() {
    final Color statusColor;
    final String statusText;
    final IconData statusIcon;

    if (_isConnected) {
      statusColor = KovaColors.success;
      statusText = 'Connected successfully!';
      statusIcon = Icons.check_circle_rounded;
    } else {
      statusColor = const Color(0xFFF5A623);
      statusText = 'Waiting for connection...';
      statusIcon = Icons.access_time_rounded;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _isConnected
              ? Icon(statusIcon, color: statusColor, size: 18)
              : Opacity(
                  opacity: _pulseOpacity.value,
                  child: Icon(statusIcon, color: statusColor, size: 18),
                ),
          const SizedBox(width: 8),
          Text(
            statusText,
            style: GoogleFonts.nunito(
              color: statusColor,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

}
