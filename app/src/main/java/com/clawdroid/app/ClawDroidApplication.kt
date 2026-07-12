package com.clawdroid.app

import android.app.Application
import com.clawdroid.app.core.config.AppConfigManager
import com.clawdroid.app.core.tools.ImageGenTools
import com.clawdroid.app.data.api.FusionRacers

class ClawDroidApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppConfigManager.init(this)

        // Wire optional FUSION racer / image-gen credentials from the build.
        // These are EMPTY by default → the app stays fully keyless out of the box.
        // When present (injected via CI secrets), they light up extra racers and
        // Cloudflare image generation without any user configuration.
        FusionRacers.novitaApiKey = BuildConfig.NOVITA_API_KEY
        FusionRacers.studentAiAnonKey = BuildConfig.STUDENTAI_ANON_KEY
        ImageGenTools.cloudflareAccountId = BuildConfig.CLOUDFLARE_ACCOUNT_ID
        ImageGenTools.cloudflareApiToken = BuildConfig.CLOUDFLARE_API_TOKEN
    }
}
