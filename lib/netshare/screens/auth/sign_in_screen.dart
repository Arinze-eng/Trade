import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/services/auth_helpers.dart';
import 'package:anywherelan/netshare/widgets/auth_scaffold.dart';
import 'package:anywherelan/netshare/widgets/password_field.dart';
import 'package:anywherelan/netshare/widgets/gradient_button.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
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

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      await SupabaseConfig.client.auth.signInWithPassword(
        email: _cleanEmail(),
        password: _password.text,
      );
    } catch (e) {
      if (!mounted) return;

      // Common Supabase case: user exists but hasn't verified email yet.
      if (AuthHelpers.isEmailNotConfirmed(e)) {
        final email = _cleanEmail();
        final shouldResend = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Verify your email'),
            content: const Text(
              'Your email is not verified yet. Please verify to sign in.\n\n'
              'Do you want us to resend the verification email?',
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

      // Better message for duplicate signup edge cases.
      if (AuthHelpers.isAlreadyRegistered(e)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This email is already registered. Please sign in.')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to continue to CDN-NETSHARE.',
      icon: Icons.login_outlined,
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
                if (value.length < 6) return 'Minimum 6 characters';
                return null;
              },
            ),
            const SizedBox(height: 18),
            GradientButton(
              onPressed: _loading ? null : _signIn,
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.login_outlined),
                        SizedBox(width: 10),
                        Text('Sign in'),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pushNamed('/sign-up'),
              child: const Text("Don't have an account? Sign up"),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).pushNamed('/resend-verification'),
              child: const Text('Resend verification email'),
            ),
          ],
        ),
      ),
    );
  }
}
