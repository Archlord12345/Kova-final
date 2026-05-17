import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:kova/core/constants.dart';
import 'package:kova/core/router.dart';
import 'package:kova/local_backend/repositories/child_repository.dart';
import 'package:kova/shared/services/network_sync_service.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/core/app_mode.dart';
import 'package:uuid/uuid.dart';

class ParentConnectionScreen extends StatefulWidget {
  const ParentConnectionScreen({super.key});

  @override
  State<ParentConnectionScreen> createState() => _ParentConnectionScreenState();
}

class _ParentConnectionScreenState extends State<ParentConnectionScreen>
    with SingleTickerProviderStateMixin {
  final List<TextEditingController> _controllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 6; i++) {
      _focusNodes[i].addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _focusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onChanged(String value, int index) {
    if (value.length > 1) {
      // Handle paste — distribute digits across boxes
      final digits = value.replaceAll(RegExp(r'\D'), '');
      for (int i = 0; i < 6 && i < digits.length; i++) {
        _controllers[i].text = digits[i];
      }
      final next = (digits.length < 6 ? digits.length : 5);
      _focusNodes[next].requestFocus();
      setState(() {});
      return;
    }

    if (value.isNotEmpty) {
      if (index < 5) {
        _focusNodes[index + 1].requestFocus();
      } else {
        _focusNodes[index].unfocus();
      }
    } else if (index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
    setState(() {});
  }

  bool get _allFilled => _controllers.every((c) => c.text.isNotEmpty);

  Future<void> _handleConnect() async {
    final code = _controllers.map((c) => c.text).join();
    if (code.length != 6) {
      _showSnack('Please enter all 6 digits of the pairing code.', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final repo = ChildRepository();
      final networkSync = NetworkSyncService();

      // Ensure device has an ID
      var deviceId = LocalStorage.getString('device_id');
      if (deviceId.isEmpty) {
        deviceId = const Uuid().v4();
        await LocalStorage.setString('device_id', deviceId);
      }

      // Claim code from Railway relay (parent assigned it)
      final pairToken = await networkSync.claimPairingCode(code);

      if (pairToken != null) {
        // Find or create child record locally
        final children = await repo.getAll();
        String childId;
        if (children.isEmpty) {
          childId = await repo.create('Connected Device');
        } else {
          childId = children.first.id;
        }

        // Code is valid online — mark linked and set child mode
        await repo.markLinked(childId);
        final success = await AppModeManager.setChildMode(childId);

        if (success) {
          // Start network sync services
          await networkSync.start(role: 'child');

          if (mounted) {
            _showSnack(
              'Connected successfully!',
              isError: false,
            );
            context.go(AppRoutes.childAccessibility);
          }
        } else if (mounted) {
          _showSnack('Failed to set device mode. Please try again.', isError: true);
        }
      } else if (mounted) {
        _showSnack('Invalid pairing code or no internet connection. Please verify the code and try again.', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack('Error connecting: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
        backgroundColor: isError ? KovaColors.danger : KovaColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showQrSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QrScannerSheet(
        onDetect: (code) {
          // Fill the code boxes
          final cleaned = code.replaceAll(RegExp(r'\D'), '');
          if (cleaned.length >= 6) {
            for (int i = 0; i < 6; i++) {
              _controllers[i].text = cleaned[i];
            }
            setState(() {});
            // Optionally auto-connect
            _handleConnect();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KovaColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: KovaColors.textPrimary,
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Title ──
              Text(
                'Connect to\nParent App',
                style: GoogleFonts.nunito(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: KovaColors.textPrimary,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter the 6-digit pairing code shown on your parent\'s KOVA app.',
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  color: KovaColors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),

              // ── Six-digit input boxes ──
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(6, (i) => _buildDigitBox(i)),
              ),

              const SizedBox(height: 40),

              // ── QR divider ──
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'or',
                      style: GoogleFonts.nunito(
                        color: KovaColors.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),

              const SizedBox(height: 32),

              // ── QR code tap button ──
              GestureDetector(
                onTap: _showQrSheet,
                child: Center(
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: KovaColors.cardWhite,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: KovaColors.primary.withValues(alpha: 0.15),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: KovaColors.primary.withValues(alpha: 0.08),
                              blurRadius: 20,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.qr_code_2_rounded,
                          size: 64,
                          color: KovaColors.primary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Scan QR Code',
                        style: GoogleFonts.nunito(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: KovaColors.primary,
                        ),
                      ),
                      Text(
                        'Tap to scan your parent\'s QR code',
                        style: GoogleFonts.nunito(
                          fontSize: 12,
                          color: KovaColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(),

              // ── Connect button ──
              AnimatedOpacity(
                opacity: _allFilled ? 1.0 : 0.5,
                duration: const Duration(milliseconds: 200),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: (_isLoading || !_allFilled) ? null : _handleConnect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KovaColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: KovaColors.primary.withValues(alpha: 0.4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Text(
                            'Connect',
                            style: GoogleFonts.nunito(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                  ),
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDigitBox(int index) {
    final isFocused = _focusNodes[index].hasFocus;
    final isFilled = _controllers[index].text.isNotEmpty;

    return SizedBox(
      width: 46,
      height: 58,
      child: TextField(
        controller: _controllers[index],
        focusNode: _focusNodes[index],
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        maxLength: 1,
        inputFormatters: [
          LengthLimitingTextInputFormatter(6), // allow paste of full code
          FilteringTextInputFormatter.digitsOnly,
        ],
        style: GoogleFonts.nunito(
          fontSize: 26,
          fontWeight: FontWeight.w900,
          color: KovaColors.primary,
        ),
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: isFocused
              ? Colors.white
              : isFilled
                  ? Colors.white
                  : const Color(0xFFF3F4F6), // Stronger subtle background
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
              color: KovaColors.divider,
              width: 1.5,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: isFilled ? KovaColors.primary : const Color(0xFFD1D5DB),
              width: isFilled ? 2.5 : 1.5,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(
              color: KovaColors.primary,
              width: 2.5,
            ),
          ),
        ),
        onChanged: (value) => _onChanged(value, index),
      ),
    );
  }
}

// ── QR Scanner Bottom Sheet ───────────────────────────────────────────────────

class _QrScannerSheet extends StatefulWidget {
  final Function(String) onDetect;
  const _QrScannerSheet({required this.onDetect});

  @override
  State<_QrScannerSheet> createState() => _QrScannerSheetState();
}

class _QrScannerSheetState extends State<_QrScannerSheet> {
  final MobileScannerController _controller = MobileScannerController();
  bool _detected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: KovaColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Text(
            'Scan Parent\'s QR Code',
            style: GoogleFonts.nunito(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: KovaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Point your camera at the KOVA parent app\nto connect instantly.',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 14,
              color: KovaColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),

          // Camera Scanner
          SizedBox(
            height: 250,
            width: 250,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: (capture) {
                      if (_detected) return;
                      final List<Barcode> barcodes = capture.barcodes;
                      for (final barcode in barcodes) {
                        final rawValue = barcode.rawValue;
                        if (rawValue != null && rawValue.startsWith('kova://pair/')) {
                          setState(() => _detected = true);
                          // Stop explicitly before callback to pop cleanly
                          _controller.stop();
                          Navigator.of(context).pop();
                          widget.onDetect(rawValue.replaceFirst('kova://pair/', ''));
                          break;
                        }
                      }
                    },
                  ),
                  // Simple scan box overlay
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: KovaColors.primary.withValues(alpha: 0.5), width: 3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Close button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              onPressed: () {
                _controller.stop();
                Navigator.of(context).pop();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: KovaColors.primary,
                side: const BorderSide(color: KovaColors.primary, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Cancel',
                style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
