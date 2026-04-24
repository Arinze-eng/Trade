import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase configuration for CDN-NETSHARE
/// NOTE: These are *publishable / anon* keys safe for client apps.
abstract final class SupabaseConfig {
  static const String url = 'https://bztwadpqoohabbemqutp.supabase.co';

  // Legacy anon key (JWT). Supabase Flutter client expects this.
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ6dHdhZHBxb29oYWJiZW1xdXRwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2OTYwNzUsImV4cCI6MjA5MjI3MjA3NX0.bu2wirl4VYE29YxagljDCabnO8GxjU_JYTQwlEaIse4';

  static SupabaseClient get client => Supabase.instance.client;
}
