import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_mode.dart';
import '../../local_backend/repositories/alert_repository.dart';
import '../../local_backend/repositories/child_repository.dart';
import '../../shared/models/network_alert.dart';
import '../../shared/services/local_storage.dart';
import '../../shared/services/network_sync_service.dart';
import '../theme/kova_theme.dart';
import 'whatsapp_connection_screen.dart';

class FinalActiveScreen extends StatefulWidget {
  const FinalActiveScreen({super.key});

  @override
  State<FinalActiveScreen> createState() => _FinalActiveScreenState();
}

class _FinalActiveScreenState extends State<FinalActiveScreen> {
  final _childRepo = ChildRepository();
  ChildModel? _child;
  bool _loading = true;

  final Map<String, _AppInfo> _allApps = {
    'whatsapp': const _AppInfo('WhatsApp', Icons.message_rounded, Color(0xFF10B981)),
    'tiktok': const _AppInfo('TikTok', Icons.video_collection_rounded, Colors.black),
    'snapchat': const _AppInfo('Snapchat', Icons.snapchat_rounded, Color(0xFFFFFC00)),
    'instagram': const _AppInfo('Instagram', Icons.camera_alt_rounded, Color(0xFFE1306C)),
    'facebook': const _AppInfo('Facebook', Icons.facebook, Color(0xFF1877F2)),
    'sms': const _AppInfo('SMS', Icons.message_outlined, Color(0xFF34C759)),
  };

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final childId = await AppModeManager.getChildId();
    if (childId != null) {
      _child = await _childRepo.getById(childId);
    }
    setState(() => _loading = false);
  }

  List<MapEntry<String, _AppInfo>> get _enabledApps {
    if (_child == null) return [];
    return _allApps.entries.where((entry) {
      final isEnabled = _child!.appControls[entry.key] ?? true;
      return isEnabled;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              Text(
                "KOVA is active",
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  fontSize: 28,
                  color: KovaTheme.primaryBlue,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Your child's phone is being monitored by KOVA AI for a safer digital experience.",
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: KovaTheme.textSecondary),
              ),
              const SizedBox(height: 48),
              const Text(
                "Current Monitoring",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: KovaTheme.textMain,
                ),
              ),
              const SizedBox(height: 16),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _enabledApps.isEmpty
                      ? const Text('No apps currently being monitored')
                      : Expanded(
                          child: ListView.builder(
                            itemCount: _enabledApps.length,
                            itemBuilder: (context, index) {
                              final app = _enabledApps[index];
                              return _monitoredApp(
                                context,
                                app.value.name,
                                "Active",
                                app.value.icon,
                                app.value.color,
                              );
                            },
                          ),
                        ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WhatsappConnectionScreen()),
                ),
                child: const Text("Go to Dashboard"),
              ),
              const SizedBox(height: 12),
              // TEST ALERT BUTTON — TEMPORARY FOR DEBUGGING
              ElevatedButton(
                onPressed: () async {
                  debugPrint('🧪 [TEST] Forcing test alert through pipeline...');

                  // Step 1: Create alert in DB
                  final alertRepo = AlertRepository();
                  final alertId = await alertRepo.create(
                    childId: LocalStorage.getString('child_id'),
                    app: 'com.whatsapp',
                    type: 'grooming',
                    severity: 'critical',
                    scoreText: 0.95,
                    scoreImage: 0.0,
                    scoreGrooming: 0.88,
                  );
                  debugPrint('✅ [TEST] Alert created in DB: id=$alertId');

                  // Step 2: Push via NetworkSyncService
                  final networkSync = NetworkSyncService();
                  debugPrint('🔍 [TEST] LAN connected=${networkSync.isLanConnected}');

                  final alert = NetworkAlertFull(
                    severity: 'critical',
                    app: 'com.whatsapp',
                    alertType: 'grooming',
                    childName: LocalStorage.getString('child_name'),
                    timestamp: DateTime.now(),
                    aiConfidence: 0.95,
                    contentPreview: 'TEST ALERT — pipeline check',
                    scoreText: 0.95,
                    scoreImage: 0.0,
                    scoreGrooming: 0.88,
                    scoreDelta: 0,
                  );

                  await networkSync.pushAlert(alert, alertId.toString());
                  debugPrint('✅ [TEST] pushAlert() completed');
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('🧪 TEST ALERT', style: TextStyle(color: Colors.white)),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _monitoredApp(
    BuildContext context,
    String name,
    String status,
    IconData icon,
    Color iconColor,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: KovaTheme.textMain,
                  ),
                ),
                Text(
                  status,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: KovaTheme.success,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.check_circle_rounded,
            color: KovaTheme.secondaryIndigo,
            size: 24,
          ),
        ],
      ),
    );
  }
}

class _AppInfo {
  final String name;
  final IconData icon;
  final Color color;
  const _AppInfo(this.name, this.icon, this.color);
}
