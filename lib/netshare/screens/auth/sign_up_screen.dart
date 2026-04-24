import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/widgets/auth_scaffold.dart';
import 'package:anywherelan/netshare/widgets/password_field.dart';
import 'package:anywherelan/netshare/widgets/gradient_button.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String _cleanEmail() => _email.text.trim().toLowerCase();

  Future<void> _resendVerificationEmail(String email) async {
    await SupabaseConfig.client.auth.resend(
      type: OtpType.signup,
      email: email,
    );
  }

  Future<Map<String, dynamic>> _checkEmailStatus(String email) async {
    // Uses DB RPC added in migration: public.check_signup_email(p_email text)
    final res = await SupabaseConfig.client.rpc(
      'check_signup_email',
      params: {'p_email': email},
    );

    // supabase_flutter returns dynamic; normalize into map
    if (res is Map) return Map<String, dynamic>.from(res);
    return const {'exists': false, 'confirmed': false};
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _cleanEmail();

    setState(() => _loading = true);
    try {
      // HARDENING: Block signup attempts for any email already in auth.users
      final status = await _checkEmailStatus(email);
      final exists = status['exists'] == true;
      final confirmed = status['confirmed'] == true;

      if (exists) {
        if (!mounted) return;

        if (confirmed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This email is already registered. Please sign in instead.'),
            ),
          );
          Navigator.of(context).pop();
          return;
        }

        // Not confirmed yet — do NOT allow creating another account.
        final shouldResend = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Email verification required'),
            content: const Text(
              'This email already started registration but is not verified yet.\n\n'
              'Please verify your email to continue. Do you want us to resend the verification email?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Resend email'),
              ),
            ],
          ),
        );

        if (shouldResend == true) {
          await _resendVerificationEmail(email);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Verification email resent. Check your inbox/spam.')),
          );
        }

        return;
      }

      final res = await SupabaseConfig.client.auth.signUp(
        email: email,
        password: _password.text,
      );

      // If email confirmations are enabled, user may not be logged in yet.
      if (res.session == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account created. Please confirm your email, then sign in.'),
          ),
        );
        Navigator.of(context).pop();
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create account',
      subtitle: 'Start your 5-day trial and secure your access.',
      icon: Icons.person_add_alt_1_outlined,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return 'Enter your email';
                if (!value.contains('@') || !value.contains('.')) return 'Invalid email';
                return null;
              },
            ),
            const SizedBox(height: 14),
            PasswordField(
              controller: _password,
              validator: (v) {
                final value = v ?? '';
                if (value.isEmpty) return 'Enter your password';
                if (value.length < 8) return 'Use at least 8 characters';
                final hasLetter = RegExp(r'[A-Za-z]').hasMatch(value);
                final hasNumber = RegExp(r'\d').hasMatch(value);
                if (!hasLetter || !hasNumber) {
                  return 'Use letters and numbers';
                }
                return null;
              },
            ),
            const SizedBox(height: 18),
            GradientButton(
              onPressed: _loading ? null : _signUp,
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_add_alt_1_outlined),
                        SizedBox(width: 10),
                        Text('Create account'),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pop(),
              child: const Text('Back to sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
