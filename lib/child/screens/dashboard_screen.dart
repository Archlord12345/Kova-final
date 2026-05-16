import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:kova/core/app_mode.dart';
import 'package:kova/child/services/detection_orchestrator.dart';
import 'package:kova/local_backend/repositories/child_repository.dart';
import 'package:kova/local_backend/repositories/alert_repository.dart';
import 'package:kova/shared/services/network_sync_service.dart';
import 'package:kova/shared/models/network_alert.dart';
import 'dart:async';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _childRepository = ChildRepository();
  final _alertRepository = AlertRepository();
  final _networkSync = NetworkSyncService();

  ChildModel? _child;
  List<AlertModel> _recentAlerts = [];
  bool _isLoading = true;
  StreamSubscription<AlertModel>? _alertSub;
  StreamSubscription<NetworkAlertSummary>? _networkAlertSub;

  List<double> _weeklyScores = List.filled(7, 100.0);
  bool _has5DayStreak = true;
  bool _isTopScorer = true;
  bool _hasKindWords = true;
  bool _isWeekChampion = true;
  bool _isPerfectWeek = true;
  bool _is100Club = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadData();
    });
    
    // Listen for local alerts from detection orchestrator
    _alertSub = DetectionOrchestrator.instance.onNewAlert.listen((alert) {
      if (mounted) {
        setState(() {
          _recentAlerts.insert(0, alert);
          if (_child != null) _calculateStats(_recentAlerts, _child!);
        });
      }
    });
    
    // Listen for parent-initiated block/unblock commands
    _networkAlertSub = _networkSync.onAlertReceived.listen((alert) {
      if (alert.alertType == 'parent_block') {
        debugPrint('🚫 [CHILD] Received parent block command for ${alert.app}');
        DetectionOrchestrator.instance.safeBlockApp(alert.app);
      } else if (alert.alertType == 'parent_unblock') {
        debugPrint('🔓 [CHILD] Received parent unblock command for ${alert.app}');
        DetectionOrchestrator.instance.unblockApp(alert.app);
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _alertSub?.cancel();
    _networkAlertSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final childId = await AppModeManager.getChildId();
    if (childId != null) {
      final child = await _childRepository.getById(childId);
      final alerts = await _alertRepository.getAll(childId: childId, limit: 1000);
      if (mounted) {
        setState(() {
          _child = child;
          _recentAlerts = alerts;
          _isLoading = false;
        });
        if (child != null) {
          _calculateStats(alerts, child);
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF6F6F6),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final childName = _child?.name ?? 'Alex';
    final score = _child?.score ?? 100;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with Logout
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hello $childName 👋',
                        style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF2C2C54),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Here's how you're doing",
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          color: const Color(0xFF888899),
                        ),
                      ),
                    ],
                  ),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).pop();
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8E8EE),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.logout_rounded, color: Color(0xFF2C2C54), size: 24),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Protection Active Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF10B981), Color(0xFF059669)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.3),
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
                        color: Colors.white.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_rounded, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Protection is Active',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Scanning for threats in real-time',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Score Ring
              Center(
                child: Column(
                  children: [
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: CustomPaint(
                        painter: SegmentedRingPainter(
                          score: score,
                          activeColor: const Color(0xFF7E3FF2),
                          inactiveColor: const Color(0xFFE8E8EE),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$score',
                                style: GoogleFonts.inter(
                                  fontSize: 48,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF7E3FF2),
                                  height: 1.1,
                                ),
                              ),
                              Text(
                                '/100',
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: const Color(0xFF888899),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _getScoreText(score),
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF7E3FF2),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),

              // "This week" Chart
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This week',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF2C2C54),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _buildChartBar('Mon', _weeklyScores[0], _getChartColor(_weeklyScores[0], 0, DateTime.now().weekday - 1)),
                        _buildChartBar('Tue', _weeklyScores[1], _getChartColor(_weeklyScores[1], 1, DateTime.now().weekday - 1)),
                        _buildChartBar('Wed', _weeklyScores[2], _getChartColor(_weeklyScores[2], 2, DateTime.now().weekday - 1)),
                        _buildChartBar('Thu', _weeklyScores[3], _getChartColor(_weeklyScores[3], 3, DateTime.now().weekday - 1)),
                        _buildChartBar('Fri', _weeklyScores[4], _getChartColor(_weeklyScores[4], 4, DateTime.now().weekday - 1)),
                        _buildChartBar('Sat', _weeklyScores[5], _getChartColor(_weeklyScores[5], 5, DateTime.now().weekday - 1)),
                        _buildChartBar('Sun', _weeklyScores[6], _getChartColor(_weeklyScores[6], 6, DateTime.now().weekday - 1)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // "Your badges"
              Text(
                'Your badges',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF2C2C54),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _has5DayStreak 
                        ? _buildBadge('5-Day\nStreak', Icons.star_border, const Color(0xFF8B5CF6))
                        : _buildLockedBadge('5-Day\nStreak', Icons.star_border),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _isTopScorer 
                        ? _buildBadge('Top\nScorer', Icons.emoji_events_outlined, const Color(0xFFF59E0B))
                        : _buildLockedBadge('Top\nScorer', Icons.emoji_events_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _hasKindWords 
                        ? _buildBadge('Kind\nWords', Icons.favorite_border, const Color(0xFFEC4899))
                        : _buildLockedBadge('Kind\nWords', Icons.favorite_border),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // "Keep going to unlock"
              Text(
                'More to unlock',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF2C2C54),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _isWeekChampion 
                        ? _buildBadge('Week\nChampion', Icons.workspace_premium_outlined, const Color(0xFF8B5CF6))
                        : _buildLockedBadge('Week\nChampion', Icons.workspace_premium_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _isPerfectWeek 
                        ? _buildBadge('Perfect\nWeek', Icons.bolt_outlined, const Color(0xFFF59E0B))
                        : _buildLockedBadge('Perfect\nWeek', Icons.bolt_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _is100Club 
                        ? _buildBadge('100 Club', Icons.adjust, const Color(0xFFEC4899))
                        : _buildLockedBadge('100 Club', Icons.adjust),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Bottom Banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFFF59E0B)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
                child: Center(
                  child: Text(
                    'Keep it up and earn your\nweekly badge! 🌟',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                      height: 1.4,
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

  String _getScoreText(int score) {
    if (score >= 90) return 'Excellent';
    if (score >= 80) return 'Great';
    if (score >= 70) return 'Good';
    if (score >= 50) return 'Needs Work';
    return 'Warning';
  }

  Color _getChartColor(double score, int index, int currentDayOfWeekIndex) {
    if (index > currentDayOfWeekIndex) {
      return const Color(0xFFD1D5DB); // Future days
    }
    if (score >= 90) return const Color(0xFF1CB476); // Green
    if (score >= 50) return const Color(0xFFF59E0B); // Orange
    return const Color(0xFFEF4444); // Red
  }

  void _calculateStats(List<AlertModel> alerts, ChildModel child) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // We want Monday (1) to Sunday (7)
    final currentDayOfWeek = now.weekday; // 1 = Monday, 7 = Sunday
    
    // Start of the week (Monday)
    final startOfWeek = today.subtract(Duration(days: currentDayOfWeek - 1));

    // Array to hold scores for the current week, index 0=Mon, 6=Sun
    final weeklyScores = List.filled(7, 100.0);
    
    // Set future days to 0.0 for the chart visual
    for (int i = currentDayOfWeek; i < 7; i++) {
      weeklyScores[i] = 0.0;
    }

    // Array to hold scores for the past 7 rolling days (for badges)
    final past7DaysScores = List.filled(7, 100.0);

    bool hasGroomingAlerts = false;

    for (final alert in alerts) {
      if (alert.scoreGrooming > 0.0) {
        hasGroomingAlerts = true;
      }

      final maxAlertScore = [alert.scoreText, alert.scoreImage, alert.scoreGrooming].reduce((a, b) => a > b ? a : b);
      final scoreImpact = maxAlertScore * 100;

      // Current week processing
      if (alert.createdAt.isAfter(startOfWeek) || alert.createdAt.isAtSameMomentAs(startOfWeek)) {
        final alertDayIndex = alert.createdAt.weekday - 1; // 0=Mon, 6=Sun
        if (alertDayIndex <= currentDayOfWeek - 1) { // Only up to today
          weeklyScores[alertDayIndex] -= scoreImpact;
          if (weeklyScores[alertDayIndex] < 10.0) weeklyScores[alertDayIndex] = 10.0;
        }
      }

      // Past 7 rolling days processing
      final daysDiff = today.difference(DateTime(alert.createdAt.year, alert.createdAt.month, alert.createdAt.day)).inDays;
      if (daysDiff >= 0 && daysDiff < 7) {
        // daysDiff = 0 is today, 1 is yesterday, etc.
        // Let's store them chronologically: index 0 is 6 days ago, index 6 is today.
        final index = 6 - daysDiff;
        past7DaysScores[index] -= scoreImpact;
        if (past7DaysScores[index] < 10.0) past7DaysScores[index] = 10.0;
      }
    }

    setState(() {
      _weeklyScores = weeklyScores;
      
      // 5-Day Streak: last 5 days (indexes 2 to 6) all >= 90
      _has5DayStreak = past7DaysScores.sublist(2).every((score) => score >= 90.0);
      
      // Top Scorer: Today's score == 100 or overall child score >= 90
      _isTopScorer = past7DaysScores[6] == 100.0 || child.score >= 90;
      
      // Kind Words: No grooming alerts ever (or at least recently)
      _hasKindWords = !hasGroomingAlerts;
      
      // Week Champion: Current week average >= 90
      final validDays = currentDayOfWeek;
      final weekAvg = weeklyScores.sublist(0, validDays).reduce((a, b) => a + b) / validDays;
      _isWeekChampion = weekAvg >= 90.0;
      
      // Perfect Week: Current week average == 100
      _isPerfectWeek = weekAvg == 100.0;
      
      // 100 Club: Overall child score == 100
      _is100Club = child.score == 100;
    });
  }

  Widget _buildChartBar(String day, double heightPct, Color color) {
    final double maxHeight = 100.0;
    // For future days (0.0 height), give a tiny 4px bar so it doesn't look broken
    final double actualHeight = heightPct == 0.0 ? 4.0 : (heightPct / 100.0) * maxHeight;

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          width: 36,
          height: actualHeight,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          day,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF888899),
          ),
        ),
      ],
    );
  }

  Widget _buildBadge(String title, IconData icon, Color bgColor) {
    return AspectRatio(
      aspectRatio: 0.9,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 36),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.white,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLockedBadge(String title, IconData icon) {
    return AspectRatio(
      aspectRatio: 0.9,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFE2E8F0),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              right: 8,
              child: const Icon(
                Icons.lock_outline,
                size: 12,
                color: Color(0xFF94A3B8),
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: const Color(0xFF94A3B8), size: 36),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF64748B),
                      height: 1.2,
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
}

class SegmentedRingPainter extends CustomPainter {
  final int score;
  final Color activeColor;
  final Color inactiveColor;

  SegmentedRingPainter({
    required this.score,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = 14.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    
    final bgPaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Draw full background ring
    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // We draw 4 segments. Total active is determined by score.
    // For 92, almost all segments are active. We'll draw 4 arcs with gaps.
    final int totalSegments = 4;
    final double gapAngle = 0.3; // radians
    final double sweepAngle = (2 * 3.141592653589793 - (gapAngle * totalSegments)) / totalSegments;
    
    int segmentsToFill = (score / 25).ceil();
    if (segmentsToFill > totalSegments) segmentsToFill = totalSegments;

    // Start angle slightly rotated so gaps align nicely (e.g. top gap, bottom gap, sides)
    double startAngle = -3.141592653589793 / 2 + (gapAngle / 2);

    for (int i = 0; i < totalSegments; i++) {
      if (i < segmentsToFill) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          startAngle,
          sweepAngle,
          false,
          fgPaint,
        );
      }
      startAngle += sweepAngle + gapAngle;
    }
  }

  @override
  bool shouldRepaint(covariant SegmentedRingPainter oldDelegate) {
    return oldDelegate.score != score;
  }
}
