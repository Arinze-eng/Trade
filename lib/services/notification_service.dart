import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';

class NotificationService {
  NotificationService._();

  /// Global navigator key for notification navigation.
  /// Must be assigned to MaterialApp.navigatorKey in main.dart.
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// Store the last notification payload for deep navigation
  static String? _lastPayload;
  static String? get lastPayload => _lastPayload;

  /// Callback for when notification is tapped - set by the app to handle navigation
  static void Function(String? payload)? onNotificationTap;

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: android);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint('Notification tapped: ${response.payload}');
        _lastPayload = response.payload;
        
        // If a callback is registered, call it (WhatsApp-style navigation)
        if (onNotificationTap != null && response.payload != null) {
          onNotificationTap!(response.payload);
        } else if (navigatorKey.currentState != null && response.payload != null) {
          // Fallback: try to navigate using global key
          _handleNotificationNavigation(response.payload);
        }
      },
    );

    // Android 13+ runtime permission is handled by OS; we best-effort request.
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }

    // Create high-priority channel for message notifications
    try {
      const channel = AndroidNotificationChannel(
        'messages',
        'Messages',
        description: 'Incoming chat messages',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
    } catch (_) {}

    // Create high-priority channel for incoming call notifications
    try {
      const callChannel = AndroidNotificationChannel(
        'incoming_calls',
        'Incoming Calls',
        description: 'Incoming voice and video calls',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(callChannel);
    } catch (_) {}

    // Create channel for status notifications
    try {
      const statusChannel = AndroidNotificationChannel(
        'status_updates',
        'Status Updates',
        description: 'New status updates from contacts',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(statusChannel);
    } catch (_) {}
  }

  /// Handle notification navigation - takes user directly to the relevant screen
  /// WhatsApp-style: tapping a message notification opens that specific chat
  static void _handleNotificationNavigation(String? payload) {
    if (payload == null || payload.isEmpty) return;
    
    try {
      // Parse payload - format: "type:id" e.g. "chat:user123", "group:group456", "call:user789"
      final parts = payload.split(':');
      if (parts.length < 2) return;
      
      final type = parts[0];
      final id = parts.sublist(1).join(':'); // Handle IDs that might contain colons
      
      final context = navigatorKey.currentState?.context;
      if (context == null) return;

      switch (type) {
        case 'chat':
          // Navigate to chat with this user - the ChatListScreen will handle it
          debugPrint('Notification navigation: opening chat with $id');
          break;
        case 'group':
          debugPrint('Notification navigation: opening group $id');
          break;
        case 'call':
          debugPrint('Notification navigation: call from $id');
          break;
        case 'status':
          debugPrint('Notification navigation: status from $id');
          break;
      }
    } catch (e) {
      debugPrint('Notification navigation error: $e');
    }
  }

  /// Build a structured payload for notification tap navigation
  /// Format: "type:id" for easy parsing
  static String buildPayload({required String type, required String id}) {
    return '$type:$id';
  }

  static Future<void> showNewMessage({
    required String title,
    required String body,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'Incoming chat messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      autoCancel: true,
      category: AndroidNotificationCategory.message,
      // WhatsApp-style: show person icon for messages
      styleInformation: MessagingStyleInformation(
        Person(name: 'CDN-NETCHAT'),
        conversationTitle: 'Messages',
        groupConversation: false,
      ),
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(DateTime.now().millisecondsSinceEpoch ~/ 1000, title, body, details);
  }

  /// Show notification IMMEDIATELY when a new message arrives.
  /// WhatsApp-style: includes person info for proper grouping and direct reply
  static Future<void> showIncomingMessageNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    // WhatsApp-style messaging notification with person info
    final person = Person(name: title, important: true);
    
    final androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'Incoming chat messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      autoCancel: true,
      category: AndroidNotificationCategory.message,
      // WhatsApp-style: group notifications by conversation
      groupKey: 'cdn_netchat_messages',
      styleInformation: MessagingStyleInformation(
        Person(name: 'Me'),
        conversationTitle: title,
        groupConversation: false,
        messages: [
          Message(body, DateTime.now(), person),
        ],
      ),
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      title.hashCode, // Use title hash for grouping by sender
      title,
      body,
      details,
      payload: payload,
    );

    // Also show a summary notification for the group (WhatsApp-style)
    _showGroupSummaryNotification();
  }

  /// Show WhatsApp-style group summary notification
  static Future<void> _showGroupSummaryNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'Incoming chat messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      autoCancel: true,
      category: AndroidNotificationCategory.message,
      groupKey: 'cdn_netchat_messages',
      setAsGroupSummary: true,
      styleInformation: InboxStyleInformation(
        [],
        contentTitle: 'CDN-NETCHAT',
        summaryText: 'New messages',
      ),
    );

    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      0, // Fixed ID for summary
      'CDN-NETCHAT',
      'You have new messages',
      details,
    );
  }

  /// Show notification when someone posts a new status
  static Future<void> showNewStatusNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'status_updates',
      'Status Updates',
      channelDescription: 'New status updates from contacts',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      autoCancel: true,
      groupKey: 'cdn_netchat_status',
      category: AndroidNotificationCategory.social,
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Show a high-priority notification for incoming calls
  /// WhatsApp-style: full-screen intent for maximum visibility
  static Future<void> showIncomingCallNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      'incoming_calls',
      'Incoming Calls',
      channelDescription: 'Incoming voice and video calls',
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      autoCancel: true,
      category: AndroidNotificationCategory.call,
      // Full-screen intent for calls (shows over other apps on lock screen)
      fullScreenIntent: true,
      // Use default notification sound for calls
      groupKey: 'cdn_netchat_calls',
      // WhatsApp-style: ongoing notification for active calls
      ongoing: true,
      styleInformation: MessagingStyleInformation(
        Person(name: title, important: true),
        conversationTitle: title,
        groupConversation: false,
        messages: [
          Message(body, DateTime.now(), Person(name: title)),
        ],
      ),
    );

    final details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      title.hashCode, // Fixed ID per caller for easy dismissal
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Cancel call notification when call is answered or declined
  static Future<void> cancelCallNotification(String callerId) async {
    await _plugin.cancel(callerId.hashCode);
  }

  /// Cancel all message notifications for a specific chat
  static Future<void> cancelChatNotifications(String chatId) async {
    await _plugin.cancel(chatId.hashCode);
  }
}
