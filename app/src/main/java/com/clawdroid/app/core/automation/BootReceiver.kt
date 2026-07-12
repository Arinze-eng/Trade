package com.clawdroid.app.core.automation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            if (com.clawdroid.app.core.config.AppConfigManager.heartbeatEnabled) {
                AutomationScheduler.schedule(context)
            } else {
                AutomationScheduler.cancel(context)
            }
        }
    }
}
