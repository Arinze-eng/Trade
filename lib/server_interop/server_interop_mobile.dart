import 'dart:developer' as developer;
import 'dart:io' as io;

import 'package:anywherelan/api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<String> initAppImpl() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (io.Platform.isAndroid) {
    return await initServerImpl();
  } else {
    throw UnsupportedError('Unsupported platform ${io.Platform.operatingSystem}');
  }
}

const platform = MethodChannel('anywherelan');
var serverRunning = false;

Future<String> initServerImpl() async {
  assert(!serverRunning, "calling initServer to running server");

  try {
    final String apiAddress = await platform.invokeMethod('start_server');
    serverAddress = "http://$apiAddress";
    serverRunning = true;
  } catch (e, s) {
    developer.log('Failed to start server', error: e, stackTrace: s, name: 'server_interop');
    return e.toString();
  }
  return "";
}

Future<void> stopServerImpl() async {
  assert(serverRunning, "calling stopServer to not running server");

  try {
    await platform.invokeMethod('stop_server');
  } catch (e, s) {
    developer.log('Failed to stop server', error: e, stackTrace: s, name: 'server_interop');
  }
  serverRunning = false;
}

// ---- Full-tunnel VPN (Android) ----

Future<String> startVpnImpl() async {
  try {
    await platform.invokeMethod('start_vpn');
  } catch (e, s) {
    developer.log('Failed to start VPN', error: e, stackTrace: s, name: 'server_interop');
    return e.toString();
  }
  return "";
}

Future<void> stopVpnImpl() async {
  try {
    await platform.invokeMethod('stop_vpn');
  } catch (e, s) {
    developer.log('Failed to stop VPN', error: e, stackTrace: s, name: 'server_interop');
  }
}

Future<bool> isVpnRunningImpl() async {
  try {
    final bool running = await platform.invokeMethod('is_vpn_running');
    return running;
  } catch (_) {
    return false;
  }
}

bool isServerRunningImpl() {
  return serverRunning;
}

Future<String> importConfigImpl(String config) async {
  assert(!serverRunning, "calling importConfig to running server");

  try {
    await platform.invokeMethod('import_config', {'config': config});
  } catch (e, s) {
    developer.log('Failed to import server config', error: e, stackTrace: s, name: 'server_interop');
    return e.toString();
  }

  return "";
}
