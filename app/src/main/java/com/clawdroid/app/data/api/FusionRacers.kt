package com.clawdroid.app.data.api

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * FusionRacers — the keyless multi-model "racer" roster for the ClawDroid FUSION brain.
 *
 * Ported from the evilgpt/HotBot backend (services/eqingChat.js, pollinations.js,
 * gemini.js, studentAI.js, novita.js). Each racer is a free / keyless (or optionally
 * keyed) LLM endpoint. The FUSION brain runs the relevant racers in parallel
 * (Mixture-of-Agents) and takes the first solid answer / tool-call, so the agent
 * always gets a strong, fast response even if one provider is down or rate-limited.
 *
 * SMART ROUTING:
 *   - TEXT-ONLY requests  → text racers (eqing, pollinations-text, studentAI) + gemini.
 *   - IMAGE / FILE requests → multimodal racers only (gemini gateway, novita-vision,
 *     pollinations-vision). Text-only racers are skipped because they cannot read images.
 *   - When a request carries an image but the caller also ran OCR, the extracted text
 *     lets ANY racer (even text-only) contribute — that fallback is handled upstream.
 *
 * Every racer exposes the same contract:
 *   suspend-free blocking call `complete(messages, tools, forcedTool): RacerResult`
 * returning plain text and/or a list of tool calls, which FusionLlmClient converts
 * into ClawDroid StreamEvents. Racers throw on failure so the fusion can fall through.
 */
object FusionRacers {

    private const val TAG = "FusionRacers"

    /** A racer's answer: assistant text plus any OpenAI-style tool calls it emitted. */
    data class RacerResult(
        val text: String,
        val toolCalls: List<CompletedToolCall> = emptyList(),
        val promptTokens: Int = 0,
        val completionTokens: Int = 0,
    ) {
        val isUsable: Boolean get() = text.isNotBlank() || toolCalls.isNotEmpty()
    }

    /** Capability flags used by the smart router. */
    enum class Modality { TEXT_ONLY, MULTIMODAL }

    /**
     * A racer definition. [modality] drives smart routing; [supportsTools] tells the
     * fusion whether this racer can emit tool calls (only tool-capable racers are used
     * when the agent needs a tool step).
     */
    data class Racer(
        val label: String,
        val modality: Modality,
        val supportsTools: Boolean,
        val enabled: () -> Boolean,
        val call: (List<ChatMessage>, JSONArray?, String?) -> RacerResult,
    )

    private val BROWSER_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"

    // ── Optional keyed overrides (read from env-like config; empty by default) ──
    // These stay empty unless the build injects them, so the app is 100% keyless
    // out of the box. Novita is the only racer that needs a key.
    @Volatile var novitaApiKey: String = ""
    @Volatile var studentAiAnonKey: String = ""

    // ─────────────────────────────────────────────────────────────────────────
    // ROUTING
    // ─────────────────────────────────────────────────────────────────────────

    /** True if any message carries inline media (image / file) → needs multimodal. */
    fun requestHasMedia(messages: List<ChatMessage>): Boolean =
        messages.any { it.mediaPath != null && it.mediaMimeType != null }

    /**
     * Pick the ordered racer panel for this request.
     *  - needsTools: the agent turn expects a tool call → only tool-capable racers.
     *  - hasMedia: request has image/file → only multimodal racers.
     * The Gemini gateway is always the anchor (strongest + multimodal + tool-capable).
     */
    fun selectRacers(hasMedia: Boolean, needsTools: Boolean): List<Racer> {
        val all = roster()
        return all.filter { racer ->
            if (!racer.enabled()) return@filter false
            if (hasMedia && racer.modality != Modality.MULTIMODAL) return@filter false
            if (needsTools && !racer.supportsTools) return@filter false
            true
        }
    }

    /** The full racer roster, strongest-first. */
    private fun roster(): List<Racer> = listOf(
        // Gemini gateway — keyless multimodal, tool-capable. The anchor brain.
        Racer(
            label = "Gemini",
            modality = Modality.MULTIMODAL,
            supportsTools = true,
            enabled = { true },
            call = ::geminiGateway,
        ),
        // Pollinations text (OpenAI-compatible, keyless). Text + tool calls.
        Racer(
            label = "Pollinations",
            modality = Modality.TEXT_ONLY,
            supportsTools = true,
            enabled = { true },
            call = { m, t, f -> pollinationsText(m, t, f) },
        ),
        // eqing / EasyChat glm-4-flash (keyless, text-only, no tools).
        Racer(
            label = "Eqing",
            modality = Modality.TEXT_ONLY,
            supportsTools = false,
            enabled = { true },
            call = { m, _, _ -> eqingText(m) },
        ),
        // StudentAI (Supabase) — text-only, optional (needs anon key).
        Racer(
            label = "StudentAI",
            modality = Modality.TEXT_ONLY,
            supportsTools = false,
            enabled = { studentAiAnonKey.isNotBlank() },
            call = { m, _, _ -> studentAiText(m) },
        ),
        // Novita vision — multimodal + tools, optional (needs paid key).
        Racer(
            label = "Novita",
            modality = Modality.MULTIMODAL,
            supportsTools = true,
            enabled = { novitaApiKey.isNotBlank() },
            call = { m, t, f -> novitaChat(m, t, f) },
        ),
    )

    // ─────────────────────────────────────────────────────────────────────────
    // RACER IMPLEMENTATIONS
    // ─────────────────────────────────────────────────────────────────────────

    /** Gemini keyless gateway (native generateContent). Multimodal + tools. */
    private fun geminiGateway(
        messages: List<ChatMessage>,
        tools: JSONArray?,
        forcedTool: String?,
    ): RacerResult {
        val payload = GeminiPayloadBuilder.build(messages, tools, forcedTool)
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        val text = httpPost(
            url = FusionLlmClient.BASE_URL + "/api/generate",
            body = body,
            headers = mapOf(
                "Authorization" to "Bearer 12345678",
                "Content-Type" to "application/json",
                "Accept" to "application/json",
                "User-Agent" to "Mozilla/5.0 (Linux; Android 14) ClawDroid/1.0",
            ),
        )
        return GeminiPayloadBuilder.parse(text)
    }

    /** Pollinations OpenAI-compatible text endpoint. Keyless. Text + tools. */
    private fun pollinationsText(
        messages: List<ChatMessage>,
        tools: JSONArray?,
        forcedTool: String?,
    ): RacerResult {
        val payload = JSONObject()
            .put("model", "openai")
            .put("messages", messages.toOpenAiJson())
            .put("stream", false)
        applyTools(payload, tools, forcedTool)
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        val text = httpPost(
            url = "https://text.pollinations.ai/openai",
            body = body,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Accept" to "application/json",
                "User-Agent" to BROWSER_UA,
            ),
        )
        return parseOpenAi(text)
    }

    /** eqing / EasyChat keyless glm-4-flash (gpt-3.5-turbo alias). Text-only. */
    private fun eqingText(messages: List<ChatMessage>): RacerResult {
        val base = "https://origin.eqing.tech"
        val payload = JSONObject()
            .put("model", "gpt-3.5-turbo")
            .put("stream", false)
            .put("messages", messages.toOpenAiJson(flattenMediaToText = true))
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        val text = httpPost(
            url = "$base/api/openai/v1/chat/completions",
            body = body,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Accept" to "application/json",
                "Origin" to base,
                "Referer" to "$base/",
                "User-Agent" to BROWSER_UA,
            ),
        )
        return parseOpenAi(text)
    }

    /** StudentAI (Supabase edge function). Optional, text-only. */
    private fun studentAiText(messages: List<ChatMessage>): RacerResult {
        val base = "https://xlhlttpjalhruxevxmtp.supabase.co"
        val payload = JSONObject()
            .put("messages", messages.toOpenAiJson(flattenMediaToText = true))
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        val text = httpPost(
            url = "$base/functions/v1/chat",
            body = body,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Accept" to "application/json",
                "apikey" to studentAiAnonKey,
                "Authorization" to "Bearer $studentAiAnonKey",
                "User-Agent" to BROWSER_UA,
            ),
        )
        // StudentAI may return either OpenAI shape or {reply|text|content}.
        val root = runCatching { JSONObject(text) }.getOrNull()
            ?: return RacerResult(text.trim())
        parseOpenAi(text).takeIf { it.isUsable }?.let { return it }
        val reply = root.optString("reply").ifBlank {
            root.optString("text").ifBlank { root.optString("content") }
        }
        return RacerResult(reply.trim())
    }

    /** Novita OpenAI-compatible chat (vision + tools). Optional, needs key. */
    private fun novitaChat(
        messages: List<ChatMessage>,
        tools: JSONArray?,
        forcedTool: String?,
    ): RacerResult {
        val payload = JSONObject()
            .put("model", "google/gemini-3.1-flash-image")
            .put("stream", false)
            .put("messages", messages.toOpenAiJson())
        applyTools(payload, tools, forcedTool)
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        val text = httpPost(
            url = "https://api.novita.ai/v3/openai/chat/completions",
            body = body,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Accept" to "application/json",
                "Authorization" to "Bearer $novitaApiKey",
                "User-Agent" to BROWSER_UA,
            ),
        )
        return parseOpenAi(text)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OpenAI response parsing (shared by pollinations / eqing / studentAI / novita)
    // ─────────────────────────────────────────────────────────────────────────

    private fun parseOpenAi(raw: String): RacerResult {
        val root = JSONObject(raw)
        // Some providers wrap errors in a 200 body.
        root.optJSONObject("error")?.let {
            throw RuntimeException("provider error: ${it.optString("message").take(160)}")
        }
        val choice = root.optJSONArray("choices")?.optJSONObject(0)
            ?: throw RuntimeException("no choices in response")
        val msg = choice.optJSONObject("message") ?: JSONObject()
        val content = msg.optString("content").orEmpty()
        val toolCalls = mutableListOf<CompletedToolCall>()
        msg.optJSONArray("tool_calls")?.let { arr ->
            for (i in 0 until arr.length()) {
                val tc = arr.optJSONObject(i) ?: continue
                val fn = tc.optJSONObject("function") ?: continue
                toolCalls.add(
                    CompletedToolCall(
                        id = tc.optString("id").ifBlank {
                            "call_" + UUID.randomUUID().toString().replace("-", "").take(12)
                        },
                        name = fn.optString("name"),
                        arguments = fn.optString("arguments").ifBlank { "{}" },
                    )
                )
            }
        }
        val usage = root.optJSONObject("usage")
        return RacerResult(
            text = content,
            toolCalls = toolCalls,
            promptTokens = usage?.optInt("prompt_tokens", 0) ?: 0,
            completionTokens = usage?.optInt("completion_tokens", 0) ?: 0,
        )
    }

    private fun applyTools(payload: JSONObject, tools: JSONArray?, forcedTool: String?) {
        if (tools == null || tools.length() == 0) return
        payload.put("tools", tools)
        payload.put(
            "tool_choice",
            if (!forcedTool.isNullOrBlank()) {
                JSONObject().put("type", "function")
                    .put("function", JSONObject().put("name", forcedTool))
            } else "auto"
        )
    }

    /** Convert ClawDroid ChatMessages to OpenAI chat messages JSON. */
    private fun List<ChatMessage>.toOpenAiJson(flattenMediaToText: Boolean = false): JSONArray {
        val arr = JSONArray()
        for (m in this) {
            val obj = JSONObject().put("role", m.role)
            // Multimodal content (image_url) unless we must flatten to text.
            if (!flattenMediaToText && m.mediaPath != null && m.mediaMimeType != null) {
                val file = java.io.File(m.mediaPath)
                if (file.exists()) {
                    val b64 = android.util.Base64.encodeToString(file.readBytes(), android.util.Base64.NO_WRAP)
                    val parts = JSONArray()
                    if (!m.content.isNullOrBlank()) {
                        parts.put(JSONObject().put("type", "text").put("text", m.content))
                    }
                    parts.put(
                        JSONObject().put("type", "image_url").put(
                            "image_url",
                            JSONObject().put("url", "data:${m.mediaMimeType};base64,$b64")
                        )
                    )
                    obj.put("content", parts)
                    arr.put(obj)
                    continue
                }
            }
            obj.put("content", m.content ?: "")
            if (m.toolCallId != null) obj.put("tool_call_id", m.toolCallId)
            if (m.toolCalls.isNotEmpty()) {
                val tcs = JSONArray()
                m.toolCalls.forEach { c ->
                    tcs.put(
                        JSONObject().put("id", c.id).put("type", "function").put(
                            "function",
                            JSONObject().put("name", c.name).put("arguments", c.arguments)
                        )
                    )
                }
                obj.put("tool_calls", tcs)
            }
            arr.put(obj)
        }
        return arr
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HTTP with browser UA + retry/backoff (shared by all racers)
    // ─────────────────────────────────────────────────────────────────────────

    private fun httpPost(
        url: String,
        body: ByteArray,
        headers: Map<String, String>,
        maxAttempts: Int = 3,
    ): String {
        var lastError = ""
        for (attempt in 0 until maxAttempts) {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15_000
                readTimeout = 90_000
                doOutput = true
                headers.forEach { (k, v) -> setRequestProperty(k, v) }
            }
            try {
                conn.outputStream.use { it.write(body) }
                val code = conn.responseCode
                if (code in 200..299) {
                    return conn.inputStream.bufferedReader().use { it.readText() }
                }
                val err = conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                lastError = "HTTP $code: ${err.take(200)}"
                val retryable = code == 403 || code == 429 || code in 500..599
                if (!retryable || attempt == maxAttempts - 1) throw RuntimeException(lastError)
            } catch (e: Exception) {
                lastError = e.message ?: e.toString()
                if (attempt == maxAttempts - 1) throw RuntimeException(lastError)
            } finally {
                conn.disconnect()
            }
            Thread.sleep(400L * (attempt + 1) + (0..200).random())
        }
        throw RuntimeException(lastError.ifBlank { "request failed" })
    }
}
