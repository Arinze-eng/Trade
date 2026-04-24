package com.anywherelan.awl

import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.annotation.NonNull
import anywherelan.Anywherelan
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger.TaskQueue
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec


class MainActivity : FlutterActivity() {
    private val CHANNEL = "anywherelan"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Get the binary messenger
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // 2. Create a background task queue from the messenger
        val taskQueue: TaskQueue = messenger.makeBackgroundTaskQueue()

        // 3. Provide the taskQueue when creating the MethodChannel
        val channel = MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE, taskQueue)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start_server" -> {
                    val startedApiAddress = Anywherelan.getApiAddress()
                    if (startedApiAddress != "") {
                        result.success(startedApiAddress)
                        return@setMethodCallHandler
                    }

                    Anywherelan.setup(this.filesDir.absolutePath)

                    try {
                        // Start backend without consuming the VPN TUN fd.
                        // Full-tunnel VPN is controlled separately via start_vpn/stop_vpn.
                        Anywherelan.startServer(0)
                        val apiAddress = Anywherelan.getApiAddress()
                        result.success(apiAddress)
                    } catch (e: Exception) {
                        result.error("error", e.message, null)
                    }
                }
                "stop_server" -> {
                    Anywherelan.stopServer()
                    result.success(null)
                }
                "start_vpn" -> {
                    val requestPermissionIntent = VpnService.prepare(this.context)
                    if (requestPermissionIntent != null) {
                        result.error("error", "vpn not authorized", null)
                        this.startActivityForResult(requestPermissionIntent, 4444)
                        return@setMethodCallHandler
                    }

                    try {
                        // Ensure service is alive
                        context.startService(Intent(context, MyVpnService::class.java))

                        val service = MyVpnService()
                        val builder: VpnService.Builder = service.builder

                        builder.setSession("CDN-NETSHARE")
                        builder.addAddress("10.0.0.2", 32)
                        builder.addRoute("0.0.0.0", 0)
                        builder.addDnsServer("8.8.8.8")
                        builder.addDnsServer("1.1.1.1")
                        builder.setMtu(1500)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            builder.setBlocking(true)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            builder.setMetered(false)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            service.setUnderlyingNetworks(null)
                        }

                        builder.establish().use { tun ->
                            if (tun == null) throw Exception("TUN_CREATION_ERROR")
                            val tunFd = tun.detachFd()
                            // Start tun2socks engine inside gomobile (TUN -> SOCKS5).
                            Anywherelan.startVPN(tunFd, "127.0.0.1:10808", 1500)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("error", e.message, null)
                    }
                }
                "stop_vpn" -> {
                    try {
                        Anywherelan.stopVPN()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("error", e.message, null)
                    }
                }
                "is_vpn_running" -> {
                    try {
                        result.success(Anywherelan.isVPNRunning())
                    } catch (e: Exception) {
                        result.error("error", e.message, null)
                    }
                }
                "import_config" -> {
                    try {
                        val text = call.argument<String>("config")
                        Anywherelan.importConfig(text)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("error", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}

class MyVpnService : android.net.VpnService() {
    val builder: Builder
        get() = Builder()

    override fun onDestroy() {
        Anywherelan.stopVPN()
        Anywherelan.stopServer()
        super.onDestroy()
    }
}
