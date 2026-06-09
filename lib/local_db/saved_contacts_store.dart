import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SavedContact {
  final String userId;
  final String uuid;
  final String displayName;
  final String username;

  const SavedContact({
    required this.userId,
    required this.uuid,
    required this.displayName,
    required this.username,
  });

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'uuid': uuid,
        'displayName': displayName,
        'username': username,
      };

  factory SavedContact.fromJson(Map<String, dynamic> json) {
    return SavedContact(
      userId: (json['userId'] ?? '').toString(),
      uuid: (json['uuid'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      username: (json['username'] ?? '').toString(),
    );
  }
}

/// Stores user-saved contacts locally (so users don't have to remember UUIDs).
class SavedContactsStore {
  static const _key = 'saved_contacts_v1';

  Future<List<SavedContact>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final arr = jsonDecode(raw);
      if (arr is! List) return const [];
      return arr
          .whereType<Map>()
          .map((e) => SavedContact.fromJson(e.cast<String, dynamic>()))
          .where((c) => c.userId.isNotEmpty && c.uuid.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> upsertFromProfile(Map<String, dynamic> profile) async {
    final userId = (profile['id'] ?? '').toString();
    final uuid = (profile['username'] ?? '').toString();
    final displayName = (profile['display_name'] ?? '').toString();
    final username = (profile['username'] ?? '').toString();

    if (userId.isEmpty || uuid.isEmpty) return;

    final sp = await SharedPreferences.getInstance();
    final current = await list();

    final next = <SavedContact>[
      SavedContact(
        userId: userId,
        uuid: uuid,
        displayName: displayName,
        username: username,
      ),
      ...current.where((c) => c.userId != userId),
    ];

    await sp.setString(_key, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<void> remove(String userId) async {
    final sp = await SharedPreferences.getInstance();
    final current = await list();
    final next = current.where((c) => c.userId != userId).toList();
    await sp.setString(_key, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key);
  }
}
