class Profile {
  final String userId;
  final String? email;
  final String status; // active | blocked
  final DateTime trialEndsAt;
  final String plan; // free | basic | premium
  final DateTime? planExpiresAt;

  const Profile({
    required this.userId,
    required this.email,
    required this.status,
    required this.trialEndsAt,
    required this.plan,
    required this.planExpiresAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      userId: json['user_id'] as String,
      email: json['email'] as String?,
      status: (json['status'] as String?) ?? 'active',
      trialEndsAt: DateTime.parse(json['trial_ends_at'] as String),
      plan: (json['plan'] as String?) ?? 'free',
      planExpiresAt: json['plan_expires_at'] == null
          ? null
          : DateTime.parse(json['plan_expires_at'] as String),
    );
  }

  bool get isBlocked => status == 'blocked';

  bool get hasActivePaidPlan {
    if (plan == 'free') return false;
    if (planExpiresAt == null) return false;
    return planExpiresAt!.isAfter(DateTime.now());
  }

  bool get hasTrial {
    return trialEndsAt.isAfter(DateTime.now());
  }

  bool get canUseApp => !isBlocked && (hasActivePaidPlan || hasTrial);
}
