import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:kova/core/app_mode.dart';
import 'package:kova/core/constants.dart';
import 'package:kova/core/router.dart';
import 'package:kova/parent/services/settings_service.dart';
import 'package:kova/parent/services/dashboard_data_service.dart';
import 'package:kova/parent/services/alert_history_service.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/shared/services/network_sync_service.dart';
import 'package:kova/local_backend/database/database_service.dart';
import 'package:kova/parent/services/app_control_service.dart';

class SettingsScreen extends StatefulWidget {
  final bool isEmbedded;

  const SettingsScreen({super.key, this.isEmbedded = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _settingsLoaded = false;
  bool _isDeveloperMode = false;
  int _tapCount = 0;

  @override
  void initState() {
    super.initState();
    _isDeveloperMode = LocalStorage.getBool('is_developer_mode', false);
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_settingsLoaded) {
      _settingsLoaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<SettingsService>().loadSettings();
      });
    }
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8, top: 24),
          child: Text(
            title.toUpperCase(),
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: KovaColors.textSecondary.withValues(alpha: 0.6),
              letterSpacing: 1.2,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: KovaColors.cardWhite,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildSettingItem(
    IconData icon,
    String title, {
    String? subtitle,
    Widget? trailing,
    bool showDivider = true,
    VoidCallback? onPressed,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onPressed,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: iconColor ?? KovaColors.primary, size: 24),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.nunito(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: KovaColors.textPrimary,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: KovaColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                // ignore: use_null_aware_elements
                if (trailing != null) trailing,
              ],
            ),
          ),
          if (showDivider)
            Divider(
              height: 1,
              indent: 56,
              endIndent: 16,
              color: KovaColors.divider.withValues(alpha: 0.4),
            ),
        ],
      ),
    );
  }

  Widget _buildEditButton(VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: KovaColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        'Edit',
        style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 13),
      ),
    );
  }

  void _showEditChildDialog(String currentName, int currentAge) {
    final nameController = TextEditingController(text: currentName);
    final ageController = TextEditingController(text: currentAge.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Child Profile', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Child Name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ageController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Age'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final newName = nameController.text.trim();
              final newAge = int.tryParse(ageController.text) ?? currentAge;
              if (newName.isNotEmpty) {
                await _updateChildProfile(newName, newAge);
                if (!context.mounted) return;
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showEditPhoneDialog(String currentPhone) {
    final phoneController = TextEditingController(text: currentPhone);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Phone Number', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
        content: TextField(
          controller: phoneController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone Number'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final newPhone = phoneController.text.trim();
              await LocalStorage.setString('parent_phone', newPhone);
              setState(() {});
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateChildProfile(String name, int age) async {
    final dashboard = context.read<DashboardDataService>();
    final child = dashboard.activeChild;
    if (child != null) {
      await context.read<DashboardDataService>().updateChildProfile(child.id, name, age);
      setState(() {});
    }
  }

  Future<void> _showDeleteChildDialog(ChildModel child) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${child.name}?', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
        content: Text(
          'This will permanently remove ${child.name} and all associated alerts and monitoring data. This action cannot be undone.',
          style: GoogleFonts.nunito(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: KovaColors.danger),
            child: Text('Delete', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (!mounted) return;
      try {
        final dashboard = context.read<DashboardDataService>();
        await dashboard.deleteChild(child.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${child.name} has been deleted', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
              backgroundColor: KovaColors.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
              backgroundColor: KovaColors.danger,
            ),
          );
        }
      }
    }
  }

  Future<void> _exportWeeklyPDF() async {
    final alertService = context.read<AlertHistoryService>();
    
    // Get all alerts from the past week
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    final allAlerts = alertService.allAlerts;
    final weeklyAlerts = allAlerts.where((a) => a.createdAt.isAfter(weekAgo)).toList();
    
    // Calculate stats
    final totalAlerts = weeklyAlerts.length;
    final resolvedAlerts = weeklyAlerts.where((a) => a.resolved).length;
    final criticalAlerts = weeklyAlerts.where((a) => a.severity == 'critical').length;
    
    // Show PDF generation dialog
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Weekly Report', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Report Period: ${weekAgo.day}/${weekAgo.month} - ${now.day}/${now.month}/${now.year}'),
            const SizedBox(height: 16),
            _buildReportStat('Total Alerts', totalAlerts.toString()),
            _buildReportStat('Resolved', resolvedAlerts.toString()),
            _buildReportStat('Critical', criticalAlerts.toString()),
            const SizedBox(height: 16),
            const Text('PDF export functionality requires pdf package integration.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildReportStat(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: GoogleFonts.nunito()),
          Text(
            value,
            style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: KovaColors.primary),
          ),
        ],
      ),
    );
  }

  void _showLegalDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Legal Information', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Privacy Policy', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'KOVA collects and processes data solely for child safety monitoring. '
                'All data is stored locally on your device. We do not share data with third parties.',
                style: GoogleFonts.nunito(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text('Terms of Service', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'By using KOVA, you agree to use this app responsibly for protecting children. '
                'This app is intended for parental monitoring of minor children only.',
                style: GoogleFonts.nunito(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text('Data Protection', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'All monitoring data is stored locally on your device. '
                'No data is transmitted to external servers without your explicit consent.',
                style: GoogleFonts.nunito(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, {VoidCallback? onTap}) {
    return TextButton(
      onPressed: onTap ?? () {},
      style: TextButton.styleFrom(
        foregroundColor: KovaColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isEmbedded) {
      return _buildBody();
    }

    return Scaffold(
      backgroundColor: KovaColors.background,
      appBar: AppBar(
        backgroundColor: KovaColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: KovaColors.textPrimary,
            size: 20,
          ),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Settings',
          style: GoogleFonts.nunito(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: KovaColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final settings = context.watch<SettingsService>();
    final dashboard = context.watch<DashboardDataService>();

    // Real data from services
    final activeChild = dashboard.activeChild;
    final childName = activeChild?.name ?? 'No child';
    final childAge = activeChild?.age ?? 0;
    final parentPhone = LocalStorage.getString('parent_phone');

    // Map language code to display name
    final languageDisplay =
        settings.language == 'fr' ? 'Français' : 'English';

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: KovaSpacing.md),
        children: [
          if (widget.isEmbedded) ...[
            const SizedBox(height: KovaSpacing.lg),
            Text(
              'Settings',
              style: GoogleFonts.nunito(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: KovaColors.textPrimary,
              ),
            ),
            const SizedBox(height: KovaSpacing.sm),
          ],
          _buildSection('Profile', [
            _buildSettingItem(
              Icons.person_outline_rounded,
              'Child name',
              subtitle: '$childName, $childAge years old',
              trailing: activeChild != null
                  ? _buildEditButton(() => _showEditChildDialog(childName, childAge))
                  : null,
            ),
            _buildSettingItem(
              Icons.local_phone_outlined,
              'Phone number',
              subtitle: parentPhone.isNotEmpty
                  ? parentPhone
                  : 'Not set',
              trailing: _buildEditButton(() => _showEditPhoneDialog(parentPhone)),
              showDivider: activeChild == null,
            ),
            if (activeChild != null)
              _buildSettingItem(
                Icons.delete_outline_rounded,
                'Delete child',
                subtitle: 'Remove $childName from monitoring',
                trailing: _buildActionButton('Delete', onTap: () => _showDeleteChildDialog(activeChild)),
                showDivider: false,
                iconColor: KovaColors.danger,
              ),
          ]),
          _buildSection('Security', [
            _buildSettingItem(
              Icons.lock_outline_rounded,
              'Change PIN',
              trailing: _buildActionButton('Change', onTap: () {
                context.push(AppRoutes.pinModification);
              }),
              showDivider: false,
            ),
          ]),
          _buildSection('Notifications', [
            _buildSettingItem(
              Icons.notifications_none_rounded,
              'Notifications',
              subtitle: settings.notificationsEnabled
                  ? 'Enabled'
                  : 'Disabled',
              trailing: Transform.scale(
                scale: 0.8,
                child: Switch.adaptive(
                  value: settings.notificationsEnabled,
                  onChanged: (v) => settings.setNotificationsEnabled(v),
                  activeTrackColor: KovaColors.primary,
                ),
              ),
            ),
            _buildSettingItem(
              Icons.volume_up_rounded,
              'Sound',
              trailing: Transform.scale(
                scale: 0.8,
                child: Switch.adaptive(
                  value: settings.soundEnabled,
                  onChanged: (v) => settings.setSoundEnabled(v),
                  activeTrackColor: KovaColors.primary,
                ),
              ),
              showDivider: false,
            ),
          ]),
          _buildSection('Language', [
            _buildSettingItem(
              Icons.language_rounded,
              'Language',
              trailing: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildLanguageToggle(
                      'Français',
                      'fr',
                      languageDisplay,
                      settings,
                    ),
                    _buildLanguageToggle(
                      'English',
                      'en',
                      languageDisplay,
                      settings,
                    ),
                  ],
                ),
              ),
              showDivider: false,
            ),
          ]),
          _buildSection('Report', [
            _buildSettingItem(
              Icons.description_outlined,
              'Export weekly PDF',
              trailing: _buildActionButton('Export', onTap: _exportWeeklyPDF),
              showDivider: false,
            ),
          ]),
          _buildSection('Network', [
            _buildSettingItem(
              Icons.wifi_off_rounded,
              'Offline Mode (LAN only)',
              subtitle: 'Use local network instead of cloud server',
              trailing: Transform.scale(
                scale: 0.8,
                child: Switch.adaptive(
                  value: LocalStorage.getBool('offline_mode', false),
                  onChanged: (v) async {
                    await LocalStorage.setBool('offline_mode', v);
                    setState(() {});
                    // Restart network sync to apply changes
                    final role = LocalStorage.getString('pair_token').isNotEmpty && 
                                 AppModeManager.currentMode == AppMode.child 
                                 ? 'child' : 'parent';
                    NetworkSyncService.instance.stop();
                    NetworkSyncService.instance.start(role: role);
                  },
                  activeTrackColor: KovaColors.primary,
                ),
              ),
            ),
            if (activeChild != null)
              _buildSettingItem(
                Icons.vibration_rounded,
                'Ping Child Device',
                subtitle: 'Test connection and vibrate phone',
                trailing: _buildActionButton('Ping', onTap: _pingChild),
                showDivider: false,
              )
            else
              const SizedBox.shrink(),
          ]),
          if (_isDeveloperMode)
          _buildSection('Server', [
            _buildSettingItem(
              Icons.dns_rounded,
              'Server URL',
              subtitle: NetworkSyncService.getRelayUrl(),
              trailing: _buildActionButton('Edit', onTap: _showServerUrlDialog),
            ),
            _buildSettingItem(
              Icons.wifi_find_rounded,
              'Server health',
              subtitle: 'Check connection',
              trailing: _buildActionButton('Check', onTap: _checkServerHealth),
            ),
            _buildSettingItem(
              Icons.science_rounded,
              'Send test alert',
              subtitle: 'Push demo notification',
              trailing: _buildActionButton('Send', onTap: _showTestAlertDialog),
              showDivider: false,
            ),
          ]),
          _buildSection('About', [
            _buildSettingItem(
              Icons.info_outline_rounded,
              'App version',
              subtitle: '1.0.0${_isDeveloperMode ? ' (DEV)' : ''}',
              onPressed: () {
                _tapCount++;
                if (_tapCount >= 5 && !_isDeveloperMode) {
                  setState(() {
                    _isDeveloperMode = true;
                    LocalStorage.setBool('is_developer_mode', true);
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🛠️ Developer Mode Enabled'),
                      backgroundColor: KovaColors.primary,
                    ),
                  );
                }
              },
              showDivider: false,
            ),
            _buildSettingItem(
              Icons.description_outlined,
              'Legal',
              trailing: _buildActionButton('View', onTap: _showLegalDialog),
              showDivider: false,
            ),
          ]),
          _buildSection('App Mode', [
            _buildSettingItem(
              Icons.swap_horiz_rounded,
              'Switch to Child Mode',
              subtitle: childName != 'No child'
                  ? "$childName's view"
                  : 'Not configured',
              trailing: _buildActionButton('Switch', onTap: () async {
                // Switch to child mode — use the child's UUID (pair code is
                // cleared after linking, so we use the persistent child ID).
                final child = dashboard.activeChild;
                if (child != null) {
                  await AppModeManager.setChildMode(child.id);
                }
                if (!mounted) return;
                context.go(AppRoutes.childDashboard);
              }),
              showDivider: true,
            ),
            _buildSettingItem(
              Icons.restart_alt_rounded,
              'Reset all settings',
              subtitle: 'Restore defaults',
              trailing: _buildActionButton('Reset', onTap: () async {
                await settings.resetToDefaults();
              }),
              showDivider: false,
            ),
          ]),
          const SizedBox(height: KovaSpacing.xl),
          OutlinedButton.icon(
            onPressed: () {
              context.push(AppRoutes.childProfile);
            },
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Add a child'),
            style: OutlinedButton.styleFrom(
              foregroundColor: KovaColors.primary,
              side: const BorderSide(color: KovaColors.divider),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: GoogleFonts.nunito(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          _buildSection('Account', [
            _buildSettingItem(
              Icons.logout_outlined,
              'Logout',
              subtitle: 'Clear all data and return to login',
              trailing: _buildActionButton('Logout', onTap: _showLogoutDialog),
              showDivider: false,
              iconColor: KovaColors.danger,
            ),
          ]),
          const SizedBox(height: KovaSpacing.xxl),
        ],
      ),
    );
  }

  // ── Server Configuration Methods ──────────────────────────────────────────

  void _showServerUrlDialog() {
    final currentUrl = NetworkSyncService.getRelayUrl();
    final urlController = TextEditingController(text: currentUrl);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Server URL', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: 'Relay Server URL',
                hintText: 'http://192.168.x.x:3000',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            Text('Presets:', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildPresetChip(
                  'Railway (prod)',
                  NetworkSyncService.railwayRelayUrl,
                  urlController,
                ),
                _buildPresetChip(
                  'Local :3000',
                  'http://192.168.1.100:3000',
                  urlController,
                ),
                _buildPresetChip('Emulator', 'http://10.0.2.2:3000', urlController),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await NetworkSyncService.resetRelayUrl();
              setState(() {});
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            child: Text('Reset', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final url = urlController.text.trim();
              if (url.isNotEmpty) {
                await NetworkSyncService.setRelayUrl(url);
                setState(() {});
              }
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: KovaColors.primary,
              foregroundColor: Colors.white,
            ),
            child: Text('Save', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChip(String label, String url, TextEditingController controller) {
    return GestureDetector(
      onTap: () => controller.text = url,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: KovaColors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: KovaColors.primary.withValues(alpha: 0.2)),
        ),
        child: Text(
          label,
          style: GoogleFonts.nunito(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: KovaColors.primary,
          ),
        ),
      ),
    );
  }

  Future<void> _pingChild() async {
    final messenger = ScaffoldMessenger.of(context);
    final activeChild = context.read<DashboardDataService>().activeChild;
    if (activeChild == null) return;
    
    messenger.showSnackBar(
      SnackBar(
        content: Text('Sending ping to ${activeChild.name}...', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
        backgroundColor: KovaColors.primary,
        duration: const Duration(seconds: 1),
      ),
    );
    
    try {
      final appControl = context.read<AppControlService>();
      await appControl.pingChild();
      
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Ping command sent successfully!', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
          backgroundColor: KovaColors.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to ping: $e', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
          backgroundColor: KovaColors.danger,
        ),
      );
    }
  }

  Future<void> _checkServerHealth() async {
    final messenger = ScaffoldMessenger.of(context);
    
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('Checking server...', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
          ],
        ),
        backgroundColor: KovaColors.primary,
        duration: const Duration(seconds: 2),
      ),
    );

    final health = await NetworkSyncService.instance.checkServerHealth();

    if (!mounted) return;
    messenger.clearSnackBars();

    if (health != null) {
      final mode = health['mode'] ?? 'unknown';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '✅ Server online — Mode: $mode',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w600),
          ),
          backgroundColor: KovaColors.success,
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '❌ Server unreachable — check URL and network',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w600),
          ),
          backgroundColor: KovaColors.danger,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _showTestAlertDialog() {
    String selectedApp = 'WhatsApp';
    String selectedSeverity = 'high';
    
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Send Test Alert', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('App', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ['WhatsApp', 'TikTok', 'Instagram', 'Snapchat'].map((app) {
                  final isSelected = selectedApp == app;
                  return GestureDetector(
                    onTap: () => setDialogState(() => selectedApp = app),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? KovaColors.primary : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        app,
                        style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isSelected ? Colors.white : KovaColors.textPrimary,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Text('Severity', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ['low', 'medium', 'high', 'critical'].map((sev) {
                  final isSelected = selectedSeverity == sev;
                  final color = sev == 'critical' || sev == 'high'
                      ? KovaColors.danger
                      : sev == 'medium'
                          ? const Color(0xFFFB8C00)
                          : KovaColors.success;
                  return GestureDetector(
                    onTap: () => setDialogState(() => selectedSeverity = sev),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? color.withValues(alpha: 0.15) : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(8),
                        border: isSelected ? Border.all(color: color) : null,
                      ),
                      child: Text(
                        sev.toUpperCase(),
                        style: GoogleFonts.nunito(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: isSelected ? color : KovaColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                final success = await NetworkSyncService.instance.sendTestAlert(
                  app: selectedApp,
                  severity: selectedSeverity,
                  alertType: 'suspicious_content',
                );
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? '🧪 Test alert sent! Check parent dashboard.'
                          : '❌ Failed to send test alert',
                      style: GoogleFonts.nunito(fontWeight: FontWeight.w600),
                    ),
                    backgroundColor: success ? KovaColors.success : KovaColors.danger,
                  ),
                );
              },
              icon: const Icon(Icons.send_rounded, size: 18),
              label: Text('Send', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
              style: ElevatedButton.styleFrom(
                backgroundColor: KovaColors.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLogoutDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Logout?', style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: KovaColors.danger)),
        content: Text(
          'This will clear ALL data and return you to the login screen:\n\n'
          '• All child profiles\n'
          '• All alerts and monitoring history\n'
          '• All settings and preferences\n'
          '• Parent account information\n\n'
          'This action cannot be undone.',
          style: GoogleFonts.nunito(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: KovaColors.danger,
              foregroundColor: Colors.white,
            ),
            child: Text('Logout', style: GoogleFonts.nunito(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Clear database
        final db = DatabaseService();
        await db.reset();
        
        // Clear all local storage
        await LocalStorage.clear();
        
        if (mounted) {
          // Show success message
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Logged out successfully', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
              backgroundColor: KovaColors.success,
            ),
          );
          
          // Navigate to splash screen
          context.go(AppRoutes.splash);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Logout failed: $e', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
              backgroundColor: KovaColors.danger,
            ),
          );
        }
      }
    }
  }

  Widget _buildLanguageToggle(
    String displayName,
    String langCode,
    String currentLanguageDisplay,
    SettingsService settings,
  ) {
    bool isSelected = currentLanguageDisplay == displayName;
    return GestureDetector(
      onTap: () => settings.setLanguage(langCode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? KovaColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          displayName,
          style: GoogleFonts.nunito(
            color: isSelected ? Colors.white : KovaColors.textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
