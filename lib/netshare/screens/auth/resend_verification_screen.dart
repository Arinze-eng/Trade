import 'package:flutter/material.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/widgets/auth_scaffold.dart';
import 'package:anywherelan/netshare/widgets/gradient_button.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ResendVerificationScreen extends StatefulWidget {
  const ResendVerificationScreen({super.key});

  @override
  State<ResendVerificationScreen> createState() => _ResendVerificationScreenState();
}

class _ResendVerificationScreenState extends State<ResendVerificationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      await SupabaseConfig.client.auth.resend(
        type: OtpType.signup,
        email: _email.text.trim().toLowerCase(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification email sent. Check inbox and spam.')),
      );
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
      title: 'Resend verification',
      subtitle: 'Missed the first email? We can send it again.',
      icon: Icons.mark_email_unread_outlined,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Instructions',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '1) Enter the email you used to sign up\n'
              '2) Tap “Resend verification”\n'
              '3) Open the email and click the verification link\n'
              '4) Come back and sign in',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 16),
            GradientButton(
              onPressed: _loading ? null : _resend,
              child: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.send_outlined),
                        SizedBox(width: 10),
                        Text('Resend verification'),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
