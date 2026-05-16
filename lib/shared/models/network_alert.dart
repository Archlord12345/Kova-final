// shared/models/network_alert.dart — Tiered alert model for network transfer

/// Lightweight alert for internet relay (Vercel) — summary only
class NetworkAlertSummary {
  final String severity;
  final String app;
  final String alertType;
  final String childName;
  final DateTime timestamp;
  final String contentPreview;

  NetworkAlertSummary({
    required this.severity,
    required this.app,
    required this.alertType,
    required this.childName,
    required this.timestamp,
    this.contentPreview = '',
  });

  Map<String, dynamic> toJson() => {
    'severity': severity,
    'app': app,
    'alertType': alertType,
    'childName': childName,
    'timestamp': timestamp.toIso8601String(),
    'contentPreview': contentPreview,
  };

  factory NetworkAlertSummary.fromJson(Map<String, dynamic> json) {
    return NetworkAlertSummary(
      severity: json['severity'] as String? ?? 'low',
      app: json['app'] as String? ?? 'unknown',
      alertType: json['alertType'] as String? ?? 'unknown',
      childName: json['childName'] as String? ?? 'Child',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      contentPreview: json['contentPreview'] as String? ?? '',
    );
  }
}

/// Full alert for LAN transfer — includes content preview and scores
class NetworkAlertFull extends NetworkAlertSummary {
  final double aiConfidence;
  final String? contentPreview;
  final String? senderInfo;
  final int scoreDelta;
  final double scoreText;
  final double scoreImage;
  final double scoreGrooming;
  final String? messageContext;

  NetworkAlertFull({
    required super.severity,
    required super.app,
    required super.alertType,
    required super.childName,
    required super.timestamp,
    required this.aiConfidence,
    this.contentPreview,
    this.senderInfo,
    this.scoreDelta = 0,
    this.scoreText = 0.0,
    this.scoreImage = 0.0,
    this.scoreGrooming = 0.0,
    this.messageContext,
  });

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'aiConfidence': aiConfidence,
    'contentPreview': contentPreview,
    'senderInfo': senderInfo,
    'scoreDelta': scoreDelta,
    'scoreText': scoreText,
    'scoreImage': scoreImage,
    'scoreGrooming': scoreGrooming,
    'messageContext': messageContext,
  };

  factory NetworkAlertFull.fromJson(Map<String, dynamic> json) {
    return NetworkAlertFull(
      severity: json['severity'] as String? ?? 'low',
      app: json['app'] as String? ?? 'unknown',
      alertType: json['alertType'] as String? ?? 'unknown',
      childName: json['childName'] as String? ?? 'Child',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      aiConfidence: (json['aiConfidence'] as num?)?.toDouble() ?? 0.0,
      contentPreview: json['contentPreview'] as String?,
      senderInfo: json['senderInfo'] as String?,
      scoreDelta: json['scoreDelta'] as int? ?? 0,
      scoreText: (json['scoreText'] as num?)?.toDouble() ?? 0.0,
      scoreImage: (json['scoreImage'] as num?)?.toDouble() ?? 0.0,
      scoreGrooming: (json['scoreGrooming'] as num?)?.toDouble() ?? 0.0,
      messageContext: json['messageContext'] as String?,
    );
  }
}

/// Device info discovered on LAN
class LanDeviceInfo {
  final String deviceId;
  final String role; // 'parent' or 'child'
  final String ipAddress;
  final int port;
  final String encryptedPairToken;
  final String encryptedTokenIv;
  final String? pairCode;
  final DateTime discoveredAt;

  LanDeviceInfo({
    required this.deviceId,
    required this.role,
    required this.ipAddress,
    required this.port,
    required this.encryptedPairToken,
    required this.encryptedTokenIv,
    this.pairCode,
    DateTime? discoveredAt,
  }) : discoveredAt = discoveredAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'role': role,
    'ip': ipAddress,
    'port': port,
    'encryptedPairToken': encryptedPairToken,
    'encryptedTokenIv': encryptedTokenIv,
    'pairCode': pairCode,
  };

  factory LanDeviceInfo.fromJson(Map<String, dynamic> json, String ip) {
    return LanDeviceInfo(
      deviceId: json['deviceId'] as String? ?? '',
      role: json['role'] as String? ?? 'unknown',
      ipAddress: ip,
      port: json['port'] as int? ?? 18757,
      encryptedPairToken: json['encryptedPairToken'] ?? json['pairToken'] as String? ?? '',
      encryptedTokenIv: json['encryptedTokenIv'] as String? ?? '',
      pairCode: json['pairCode'] as String?,
    );
  }
}

/// Connection state enum
enum NetworkConnectionState {
  /// Connected via local WiFi — full data transfer
  lan,
  /// Connected via internet relay — summary only
  internet,
  /// Connection error / unreachable
  error,
  /// No connection available
  none,
}
