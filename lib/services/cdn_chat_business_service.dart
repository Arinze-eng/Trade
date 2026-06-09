// CDN CHAT Business Service
// Subscriptions, Earnings, Wallet, Referrals, Boosted Status
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_tier.dart';

class CdnChatBusinessService {
  static final CdnChatBusinessService _instance =
      CdnChatBusinessService._internal();
  factory CdnChatBusinessService() => _instance;
  CdnChatBusinessService._internal();

  static final SupabaseClient _client = Supabase.instance.client;

  // Earning rates
  static const double statusViewRate = 2.50;
  static const double messageSentRate = 0.75;
  static const double referralRate = 50.0;
  static const double streakBonus = 20.0;
  static const double dailyCap = 2000.0;
  static const double cashOutMin = 5000.0;

  // Subscription prices
  static const int basicPremiumPrice = 4000;
  static const int proPrice = 30000;

  // Boosted status price
  static const int boostedStatusPrice = 3000;
  static const int boostedStatusViews = 1000;

  // ========== Subscription / Tier ==========

  Future<UserTier> getUserTier(String userId) async {
    try {
      final res =
          await _client
              .from('profiles')
              .select('tier')
              .eq('id', userId)
              .single();
      return UserTier.fromApi(res['tier']?.toString());
    } catch (e) {
      debugPrint('getUserTier error: $e');
      return UserTier.free;
    }
  }

  Future<Map<String, dynamic>?> getSubscriptionDetails(String userId) async {
    try {
      final res =
          await _client
              .from('subscriptions')
              .select('*')
              .eq('user_id', userId)
              .eq('status', 'active')
              .order('created_at', ascending: false)
              .limit(1)
              .single();
      return res;
    } catch (_) {
      return null;
    }
  }

  Future<bool> activateSubscription({
    required String userId,
    required UserTier tier,
    required String paymentProvider,
    required String paymentReference,
  }) async {
    try {
      final amount = tier == UserTier.pro ? proPrice : basicPremiumPrice;
      final now = DateTime.now();
      final endDate = now.add(const Duration(days: 30));

      await _client.from('subscriptions').insert({
        'user_id': userId,
        'tier': tier.apiValue,
        'amount': amount,
        'payment_provider': paymentProvider,
        'payment_reference': paymentReference,
        'status': 'active',
        'start_date': now.toUtc().toIso8601String(),
        'end_date': endDate.toUtc().toIso8601String(),
      });

      await _client
          .from('profiles')
          .update({
            'tier': tier.apiValue,
            'is_subscribed': true,
            'subscription_started_at': now.toUtc().toIso8601String(),
            'subscription_ends_at': endDate.toUtc().toIso8601String(),
          })
          .eq('id', userId);

      return true;
    } catch (e) {
      debugPrint('activateSubscription error: $e');
      return false;
    }
  }

  // ========== Earnings Engine ==========

  Future<Map<String, dynamic>> recordEarning({
    required String userId,
    required double amount,
    required String source,
    String? referenceId,
  }) async {
    try {
      final res = await _client.rpc(
        'record_earning',
        params: {
          'p_user_id': userId,
          'p_amount': amount,
          'p_source': source,
          'p_reference_id': referenceId ?? '',
        },
      );
      if (res != null && res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return {'success': false, 'error': 'Unknown response'};
    } catch (e) {
      debugPrint('recordEarning error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<double> getDailyEarnings(String userId) async {
    try {
      final res = await _client.rpc(
        'get_daily_earnings',
        params: {'p_user_id': userId},
      );
      return (res as num?)?.toDouble() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<double> getUserBalance(String userId) async {
    try {
      final res = await _client.rpc(
        'get_user_balance',
        params: {'p_user_id': userId},
      );
      return (res as num?)?.toDouble() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<double> getTotalEarnings(String userId) async {
    try {
      final res =
          await _client
              .from('profiles')
              .select('total_earnings')
              .eq('id', userId)
              .single();
      return (res['total_earnings'] as num?)?.toDouble() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<Map<String, dynamic>> awardStreakBonus(String userId) async {
    try {
      final res = await _client.rpc(
        'award_streak_bonus',
        params: {'p_user_id': userId},
      );
      if (res != null && res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return {'success': false, 'error': 'Unknown'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<int> updateStreak(String userId) async {
    try {
      final res = await _client.rpc(
        'update_streak',
        params: {'p_user_id': userId},
      );
      return (res as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  // ========== Earnings History ==========

  Future<List<Map<String, dynamic>>> getEarningsHistory(
    String userId, {
    int limit = 50,
  }) async {
    try {
      final res = await _client
          .from('earnings')
          .select('*')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(res);
    } catch (_) {
      return [];
    }
  }

  // ========== Wallet / Transactions ==========

  Future<List<Map<String, dynamic>>> getTransactions(
    String userId, {
    int limit = 50,
  }) async {
    try {
      final res = await _client
          .from('transactions')
          .select('*')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(res);
    } catch (_) {
      return [];
    }
  }

  // ========== Cash Out ==========

  Future<bool> requestCashOut({
    required String userId,
    required double amount,
    required String method,
    required Map<String, dynamic> accountDetails,
    String? fullName,
    String? accountNumber,
    String? bank,
    String? email,
  }) async {
    try {
      if (amount < cashOutMin) return false;

      final balance = await getUserBalance(userId);
      if (amount > balance) return false;

      await _client.from('cash_out_requests').insert({
        'user_id': userId,
        'amount': amount,
        'method': method,
        'account_details': accountDetails,
        'status': 'pending',
        'full_name': fullName ?? accountDetails['full_name'] ?? '',
        'account_number': accountNumber ?? accountDetails['account_number'] ?? '',
        'bank': bank ?? accountDetails['bank'] ?? '',
        'email': email ?? accountDetails['email'] ?? '',
      });

      // Record the cash out transaction
      final newBalance = balance - amount;
      await _client.from('transactions').insert({
        'user_id': userId,
        'type': 'cash_out',
        'amount': amount,
        'balance_before': balance,
        'balance_after': newBalance,
        'status': 'pending',
        'description': 'Cash out via $method',
      });

      return true;
    } catch (e) {
      debugPrint('requestCashOut error: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getCashOutHistory(String userId) async {
    try {
      final res = await _client
          .from('cash_out_requests')
          .select('*')
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res);
    } catch (_) {
      return [];
    }
  }

  // ========== Referral System ==========

  Future<String> getOrCreateReferralCode(String userId) async {
    try {
      final res =
          await _client
              .from('profiles')
              .select('referral_code')
              .eq('id', userId)
              .single();
      String? code = res['referral_code']?.toString();
      if (code != null && code.isNotEmpty) return code;

      // Generate new code
      code = _generateReferralCode();
      await _client
          .from('profiles')
          .update({'referral_code': code})
          .eq('id', userId);
      return code;
    } catch (_) {
      return _generateReferralCode();
    }
  }

  String _generateReferralCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = DateTime.now().microsecondsSinceEpoch;
    String code = '';
    for (int i = 0; i < 8; i++) {
      code += chars[(rand >> (i * 3)) % chars.length];
    }
    return code;
  }

  Future<bool> applyReferral({
    required String referralCode,
    required String newUserId,
  }) async {
    try {
      // Find the referrer
      final res =
          await _client
              .from('profiles')
              .select('id')
              .eq('referral_code', referralCode)
              .single();
      final referrerId = res['id']?.toString();
      if (referrerId == null || referrerId == newUserId) return false;

      // Create referral record
      await _client.from('referrals').insert({
        'referrer_id': referrerId,
        'referred_user_id': newUserId,
        'referral_code': referralCode,
        'status': 'pending',
      });

      // Update referrer count
      await _client.rpc(
        'increment_referral_count',
        params: {'p_user_id': referrerId},
      );

      return true;
    } catch (e) {
      debugPrint('applyReferral error: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getReferrals(String userId) async {
    try {
      final res = await _client
          .from('referrals')
          .select('*, referred:referred_user_id(username, display_name)')
          .eq('referrer_id', userId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res);
    } catch (_) {
      return [];
    }
  }

  // Check if referral should be paid (referred user sent >= 10 messages)
  Future<void> checkReferralCompletion(String newUserId) async {
    try {
      // Count messages sent by the new user
      final msgCount = await _client
          .from('messages')
          .select('id')
          .eq('sender_id', newUserId);

      final count = msgCount.length;
      if (count < 10) return;

      // Find pending referrals for this user
      final refs = await _client
          .from('referrals')
          .select('*')
          .eq('referred_user_id', newUserId)
          .eq('status', 'pending');

      for (final ref in refs) {
        final referrerId = ref['referrer_id']?.toString();
        if (referrerId == null) continue;

        // Pay the referrer
        await recordEarning(
          userId: referrerId,
          amount: referralRate,
          source: 'referral',
          referenceId: ref['id']?.toString(),
        );

        // Mark referral as paid
        await _client
            .from('referrals')
            .update({
              'status': 'paid',
              'messages_sent': count,
              'paid_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', ref['id']);
      }
    } catch (e) {
      debugPrint('checkReferralCompletion error: $e');
    }
  }

  // ========== Boosted Status ==========

  Future<bool> boostStatus({
    required String userId,
    required String statusId,
    required String paymentReference,
  }) async {
    try {
      await _client
          .from('status')
          .update({
            'is_boosted': true,
            'boost_views_target': boostedStatusViews,
            'boost_views_delivered': 0,
          })
          .eq('id', statusId);

      // Record payment transaction
      final balance = await getUserBalance(userId);
      await _client.from('transactions').insert({
        'user_id': userId,
        'type': 'boost_payment',
        'amount': boostedStatusPrice,
        'balance_before': balance,
        'balance_after': balance - boostedStatusPrice,
        'status': 'completed',
        'description': 'Boosted Status - $boostedStatusViews extra views',
      });

      return true;
    } catch (e) {
      debugPrint('boostStatus error: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getSponsoredSlots() async {
    try {
      final res = await _client
          .from('sponsored_status_slots')
          .select('*')
          .eq('status', 'active')
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res);
    } catch (_) {
      return [];
    }
  }

  // ========== Profile with earnings info ==========

  Future<Map<String, dynamic>> getFullProfile(String userId) async {
    try {
      final res =
          await _client.from('profiles').select('*').eq('id', userId).single();
      return Map<String, dynamic>.from(res);
    } catch (_) {
      return {};
    }
  }
}
