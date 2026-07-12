package com.clawdroid.app.core.tools

import android.content.Context
import com.clawdroid.app.core.bootstrap.EnvironmentSetup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * ImageGenTools — text-to-image generation for the agent.
 *
 * Two backends, keyless-first so it works out of the box:
 *   1. Cloudflare Workers AI (@cf/black-forest-labs/flux-1-schnell) — used when a
 *      CF account id + API token are configured (Settings / BuildConfig).
 *   2. Pollinations image endpoint (https://image.pollinations.ai) — fully
 *      keyless fallback, matches the FUSION brain's keyless philosophy.
 *
 * The generated image is written into the agent's workspace so the user can see
 * and reuse it, and the tool returns the saved path.
 */
object ImageGenTools {

    // Optional Cloudflare config. Empty by default → keyless Pollinations is used.
    @Volatile var cloudflareAccountId: String = ""
    @Volatile var cloudflareApiToken: String = ""
    @Volatile var cloudflareModel: String = "@cf/black-forest-labs/flux-1-schnell"

    suspend fun generate(
        context: Context,
        prompt: String,
        width: Int = 1024,
        height: Int = 1024,
        outPath: String? = null,
    ): JSONObject = withContext(Dispatchers.IO) {
        require(prompt.isNotBlank()) { "prompt is required" }
        val env = EnvironmentSetup.build(context)
        val outDir = File(env.home, "output").apply { mkdirs() }
        val target = when {
            outPath.isNullOrBlank() -> File(outDir, "image_${System.currentTimeMillis()}.png")
            outPath.startsWith("/") -> File(outPath)
            else -> File(env.home, outPath)
        }
        target.parentFile?.mkdirs()

        val (bytes, model) = if (cloudflareAccountId.isNotBlank() && cloudflareApiToken.isNotBlank()) {
            runCatching { cloudflareImage(prompt, width, height) }
                .getOrElse { pollinationsImage(prompt, width, height) }
        } else {
            pollinationsImage(prompt, width, height)
        }

        target.writeBytes(bytes)
        JSONObject()
            .put("path", target.absolutePath)
            .put("bytes", bytes.size)
            .put("model", model)
            .put("prompt", prompt)
    }

    /** Cloudflare Workers AI flux image → PNG bytes. */
    private fun cloudflareImage(prompt: String, width: Int, height: Int): Pair<ByteArray, String> {
        val url = "https://api.cloudflare.com/client/v4/accounts/$cloudflareAccountId/ai/run/$cloudflareModel"
        val payload = JSONObject()
            .put("prompt", prompt)
            .put("width", width)
            .put("height", height)
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 20_000
            readTimeout = 120_000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $cloudflareApiToken")
            setRequestProperty("Content-Type", "application/json")
        }
        try {
            conn.outputStream.use { it.write(payload.toString().toByteArray()) }
            val code = conn.responseCode
            if (code !in 200..299) {
                val err = conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                throw RuntimeException("Cloudflare image HTTP $code: ${err.take(200)}")
            }
            val ctype = conn.contentType ?: ""
            // flux-1-schnell returns JSON { result: { image: <base64> } }; some
            // CF image models return raw image bytes directly.
            return if (ctype.contains("application/json", ignoreCase = true)) {
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                val root = JSONObject(body)
                val b64 = root.optJSONObject("result")?.optString("image").orEmpty()
                    .ifBlank { root.optString("image") }
                if (b64.isBlank()) throw RuntimeException("Cloudflare image: no image in response")
                android.util.Base64.decode(b64, android.util.Base64.DEFAULT) to "cloudflare/$cloudflareModel"
            } else {
                conn.inputStream.readBytes() to "cloudflare/$cloudflareModel"
            }
        } finally {
            conn.disconnect()
        }
    }

    /** Pollinations keyless image endpoint → image bytes. */
    private fun pollinationsImage(prompt: String, width: Int, height: Int): Pair<ByteArray, String> {
        val p = URLEncoder.encode(prompt.trim(), "UTF-8")
        val url = "https://image.pollinations.ai/prompt/$p?model=flux&width=$width&height=$height&nologo=true"
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 20_000
            readTimeout = 120_000
            setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) ClawDroid/1.0")
            setRequestProperty("Accept", "image/*")
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                val err = conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                throw RuntimeException("Pollinations image HTTP $code: ${err.take(200)}")
            }
            return conn.inputStream.readBytes() to "pollinations/flux"
        } finally {
            conn.disconnect()
        }
    }
}
