import 'dart:async';

import 'package:anywherelan/add_peer.dart';
import 'package:anywherelan/app_shell.dart';
import 'package:anywherelan/drawer.dart';
import 'package:anywherelan/notifications.dart' as notif;
import 'package:anywherelan/peers_list_tab.dart';
import 'package:anywherelan/providers.dart';
import 'package:anywherelan/status_tab.dart';

import 'package:anywherelan/netshare/widgets/app_background.dart';
import 'package:anywherelan/netshare/config/supabase_config.dart';
import 'package:anywherelan/netshare/screens/account_screen.dart';
import 'package:anywherelan/netshare/screens/payments/payment_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// AWL dashboard wrapped in CDN-NETSHARE visuals so it blends in.
///
/// Functionality stays the same: Status + Peers (add/config).
class AwlDashboardScreen extends ConsumerStatefulWidget {
  static const String routeName = '/awl';

  const AwlDashboardScreen({super.key});

  @override
  ConsumerState<AwlDashboardScreen> createState() => _AwlDashboardScreenState();
}

class _AwlDashboardScreenState extends ConsumerState<AwlDashboardScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  late final notif.NotificationsService _notificationsService;

  @override
  void initState() {
    super.initState();

    _notificationsService = notif.NotificationsService(ref.read(apiProvider));
    _notificationsService.init();
    WidgetsBinding.instance.addObserver(this);

    _tabController = TabController(vsync: this, length: 2, initialIndex: 1);
    // IMPORTANT: Avoid rebuilding the whole dashboard on every tab animation tick.
    // We only rebuild the FAB via an AnimatedBuilder in build().

  }

  @override
  void dispose() {
    _tabController.dispose();

    WidgetsBinding.instance.removeObserver(this);
    _notificationsService.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.paused:
        ref.read(pollingPolicyProvider.notifier).state = PollingPolicy.paused;
        _notificationsService.setTimerIntervalLong();
        break;
      case AppLifecycleState.resumed:
        ref.read(pollingPolicyProvider.notifier).state = PollingPolicy.active;
        _notificationsService.setTimerIntervalShort();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/icons/awl.png',
                width: 28,
                height: 28,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(width: 8),
              const Text('CDN'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Subscribe / Plans',
              icon: const Icon(Icons.workspace_premium_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PaymentScreen()),
                );
              },
            ),
            IconButton(
              tooltip: 'Account',
              icon: const Icon(Icons.person_outline),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                );
              },
            ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'logout') {
                  await SupabaseConfig.client.auth.signOut();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'logout',
                  child: Text('Log out'),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            isScrollable: false,
            tabs: const [
              Tab(text: 'Status'),
              Tab(text: 'Peers'),
            ],
          ),
        ),
        drawer: MyDrawer(selected: AppSection.overview),
        body: SafeArea(
          bottom: false,
          child: TabBarView(
            controller: _tabController,
            children: const [
              Padding(padding: EdgeInsets.all(16), child: StatusPage()),
              Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: PeersListPage()),
            ],
          ),
        ),
        floatingActionButton: AnimatedBuilder(
          animation: _tabController,
          builder: (context, _) {
            if (_tabController.index != 1) return const SizedBox.shrink();
            return FloatingActionButton(
              tooltip: 'Add new peer',
              onPressed: () {
                showAddPeerDialog(context);
              },
              child: const Icon(Icons.add),
            );
          },
        ),
      ),
    );
  }
}
