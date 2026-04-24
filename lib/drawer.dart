import 'dart:async';

import 'package:anywherelan/app_shell.dart';
import 'package:anywherelan/blocked_peers_screen.dart';
import 'package:anywherelan/diagnostics_screen.dart';
import 'package:anywherelan/providers.dart';
import 'package:anywherelan/server_interop/server_interop.dart';
import 'package:anywherelan/settings_screen.dart' show AppSettingsScreen;
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/screens/account_screen.dart';
import 'package:anywherelan/netshare/screens/payments/payment_screen.dart';
import 'package:anywherelan/netshare/screens/how_to_share_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher_string.dart';

const _supportEmail = 'cdnnetshare123@gmail.com';
const _supportWhatsAppUrl = 'https://wa.me/2349048554985';
const _supportMailtoUrl = 'mailto:cdnnetshare123@gmail.com?subject=CDN%20NetShare%20Support';

class MyDrawer extends ConsumerStatefulWidget {
  final AppSection? selected;
  final bool isRetractable;

  const MyDrawer({super.key, this.selected, this.isRetractable = true});

  @override
  ConsumerState<MyDrawer> createState() => _MyDrawerState();
}

class _MyDrawerState extends ConsumerState<MyDrawer> {
  static const _sectionOrder = [
    AppSection.overview,
    AppSection.settings,
    AppSection.blockedPeers,
    AppSection.diagnostics,
  ];

  @override
  Widget build(BuildContext context) {
    final serverGatedEnabled = kIsWeb || isServerRunning();
    final user = SupabaseConfig.client.auth.currentUser;
    final selectedIndex = widget.selected != null ? _sectionOrder.indexOf(widget.selected!) : null;

    final destinations = <NavigationDrawerDestination>[
      const NavigationDrawerDestination(
        icon: Icon(Icons.hub_outlined),
        selectedIcon: Icon(Icons.hub),
        label: Text('Overview'),
      ),
      const NavigationDrawerDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: Text('Settings'),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.block_outlined),
        selectedIcon: const Icon(Icons.block),
        enabled: serverGatedEnabled,
        label: const Text('Blocked peers'),
      ),
      NavigationDrawerDestination(
        icon: const Icon(Icons.bug_report_outlined),
        selectedIcon: const Icon(Icons.bug_report),
        enabled: serverGatedEnabled,
        label: const Text('Diagnostics'),
      ),
    ];

    final children = <Widget>[
      if (widget.isRetractable) const SizedBox(height: 12),
      if (!kIsWeb)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _serverAction(context)),
      if (!kIsWeb && isServerRunning())
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _restartAction(context)),
      if (!kIsWeb)
        const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8), child: Divider(height: 1)),
      ...destinations,
      const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8), child: Divider(height: 1)),

      // CDN-NETSHARE: Account / Subscription / Logout
      if (user != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(
              user.email ?? 'Account',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            subtitle: const Text('View your account details'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AccountScreen()),
              );
            },
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.workspace_premium_outlined),
          title: Text('Subscription', style: Theme.of(context).textTheme.labelLarge),
          subtitle: const Text('Choose or manage your plan'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PaymentScreen()),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.speed),
          title: Text('Speed test', style: Theme.of(context).textTheme.labelLarge),
          subtitle: const Text('Test your internet speed'),
          onTap: () {
            Navigator.of(context).pushNamed('/speed-test');
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text('How to share internet', style: Theme.of(context).textTheme.labelLarge),
          subtitle: const Text('Step-by-step guide'),
          onTap: () {
            Navigator.of(context).pushNamed(HowToShareScreen.routeName);
          },
        ),
      ),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8), child: Divider(height: 1)),

      // Support
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.support_agent_outlined),
          title: Text('Contact support', style: Theme.of(context).textTheme.labelLarge),
          subtitle: Text(_supportEmail),
          onTap: () async {
            _closeDrawerIfModal(context);
            await launchUrlString(_supportMailtoUrl);
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text('WhatsApp support', style: Theme.of(context).textTheme.labelLarge),
          subtitle: const Text('+90 485 549 85'),
          onTap: () async {
            _closeDrawerIfModal(context);
            await launchUrlString(_supportWhatsAppUrl);
          },
        ),
      ),

      const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8), child: Divider(height: 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.logout_rounded),
          title: Text('Log out', style: Theme.of(context).textTheme.labelLarge),
          onTap: () async {
            _closeDrawerIfModal(context);
            await SupabaseConfig.client.auth.signOut();
          },
        ),
      ),

    ];

    final drawer = NavigationDrawer(
      selectedIndex: (selectedIndex != null && selectedIndex >= 0) ? selectedIndex : null,
      onDestinationSelected: (index) => _navigateToSection(context, _sectionOrder[index]),
      children: children,
    );

    if (widget.isRetractable) {
      return drawer;
    }
    return SizedBox(width: 240, child: drawer);
  }

  Widget _serverAction(BuildContext context) {
    final running = isServerRunning();
    return ListTile(
      leading: Icon(running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
      title: Text(running ? 'Stop' : 'Start', style: Theme.of(context).textTheme.labelLarge),
      onTap: () async {
        final container = ProviderScope.containerOf(context);
        _closeDrawerIfModal(context);
        var message = '';
        var isError = false;
        if (isServerRunning()) {
          await stopServer();
          message = 'Server stopped';
          unawaited(refreshProviders(container).catchError((_) {}));
        } else {
          final startResponse = await initServer();
          if (startResponse == '') {
            message = 'Server started';
            unawaited(refreshProvidersRepeated(container));
          } else {
            message = 'Failed to start server: $startResponse';
            isError = true;
          }
        }
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: isError
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
            content: Text(message),
          ),
        );
      },
    );
  }

  Widget _restartAction(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.refresh),
      title: Text('Restart', style: Theme.of(context).textTheme.labelLarge),
      onTap: () async {
        final container = ProviderScope.containerOf(context);
        _closeDrawerIfModal(context);
        if (isServerRunning()) await stopServer();
        final startResponse = await initServer();
        if (!context.mounted) return;
        if (startResponse == '') {
          unawaited(refreshProvidersRepeated(container));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              content: const Text('Server restarted'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Theme.of(context).colorScheme.error,
              content: Text('Failed to start server: $startResponse'),
            ),
          );
        }
      },
    );
  }

  void _navigateToSection(BuildContext context, AppSection section) {
    _closeDrawerIfModal(context);
    if (section == widget.selected) return;
    final navigator = Navigator.of(context);
    if (section == AppSection.overview) {
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    final routeName = _routeFor(section);
    if (widget.selected == null || widget.selected == AppSection.overview) {
      navigator.pushNamed(routeName);
    } else {
      navigator.pushReplacementNamed(routeName);
    }
  }

  static String _routeFor(AppSection section) {
    switch (section) {
      case AppSection.overview:
        return '/';
      case AppSection.settings:
        return AppSettingsScreen.routeName;
      case AppSection.blockedPeers:
        return BlockedPeersScreen.routeName;
      case AppSection.diagnostics:
        return DiagnosticsScreen.routeName;
    }
  }

  void _closeDrawerIfModal(BuildContext context) {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }

  List<Widget> _buildAboutBox() {
    final TextStyle textStyle = Theme.of(context).textTheme.bodyLarge!;
    const url = "https://anywherelan.com";
    return <Widget>[
      SizedBox(height: 24),
      RichText(
        text: TextSpan(
          children: <TextSpan>[
            TextSpan(
              style: textStyle.copyWith(color: Theme.of(context).colorScheme.primary),
              text: url,
              recognizer: TapGestureRecognizer()
                ..onTap = () async {
                  if (await canLaunchUrlString(url)) await launchUrlString(url);
                },
            ),
          ],
        ),
      ),
    ];
  }
}
