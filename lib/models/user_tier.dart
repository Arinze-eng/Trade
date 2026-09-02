// User subscription tiers for CDN CHAT earning system
enum UserTier {
  free,
  basicPremium,
  pro;

  String get apiValue {
    switch (this) {
      case UserTier.free:
        return 'free';
      case UserTier.basicPremium:
        return 'basic_premium';
      case UserTier.pro:
        return 'pro';
    }
  }

  static UserTier fromApi(String? value) {
    switch (value) {
      case 'basic_premium':
        return UserTier.basicPremium;
      case 'pro':
        return UserTier.pro;
      default:
        return UserTier.free;
    }
  }

  String get displayName {
    switch (this) {
      case UserTier.free:
        return 'Free';
      case UserTier.basicPremium:
        return 'Basic Premium';
      case UserTier.pro:
        return 'Pro';
    }
  }

  String get monthlyPrice {
    switch (this) {
      case UserTier.free:
        return '₦0';
      case UserTier.basicPremium:
        return '₦4,000';
      case UserTier.pro:
        return '₦30,000';
    }
  }

  int get monthlyPriceNaira {
    switch (this) {
      case UserTier.free:
        return 0;
      case UserTier.basicPremium:
        return 4000;
      case UserTier.pro:
        return 30000;
    }
  }

  bool get canEarn => this != UserTier.free;
  bool get canCreateChannels => this == UserTier.pro;
  bool get hasAiChat => this == UserTier.pro;
  bool get hasAutoReply => this == UserTier.pro;
  bool get isAdFree => this != UserTier.free;
  bool get hasCustomThemes => this != UserTier.free;
  bool get hasLargeFileSharing => this != UserTier.free;
}
