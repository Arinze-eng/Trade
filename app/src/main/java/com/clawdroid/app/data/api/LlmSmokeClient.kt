package com.clawdroid.app.data.api

import com.clawdroid.app.BuildConfig
import com.clawdroid.app.core.config.AppConfigManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class ModelTestResult(
    val model: String,
    val content: String,
)

object LlmSmokeClient {
    suspend fun runSmokeTest(): ModelTestResult = withContext(Dispatchers.IO) {
        // Route through AppConfigManager so the inbuilt keyless FUSION brain
        // (or any user-configured provider) is honoured. Falls back to the
        // effective config rather than raw BuildConfig, which may be blank when
        // the inbuilt FUSION brain is active.
        val baseUrl = AppConfigManager.baseUrl.trimEnd('/')
        val apiKey = AppConfigManager.apiKey
        val model = AppConfigManager.model
        val provider = AppConfigManager.provider
        check(baseUrl.isNotBlank()) { "Missing LLM base URL" }
        check(model.isNotBlank()) { "Missing LLM model" }

        // Inbuilt FUSION brain has no /chat/completions endpoint — use the
        // FUSION-aware streaming client for the smoke test instead.
        if (FusionLlmClient.isFusion(baseUrl, provider)) {
            return@withContext runStreamingSmokeTest()
        }

        check(apiKey.isNotBlank()) { "Missing LLM API key" }

        val payload = JSONObject()
            .put("model", model)
            .put(
                "messages",
                JSONArray()
                    .put(
                        JSONObject()
                            .put("role", "system")
                            .put("content", "Reply with one short sentence.")
                    )
                    .put(
                        JSONObject()
                            .put("role", "user")
                            .put("content", "Say ClawDroid model smoke test ok.")
                    )
            )
            .put("temperature", 0)

        val connection = (URL("$baseUrl/chat/completions").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 20_000
            readTimeout = 60_000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $apiKey")
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("HTTP-Referer", "https://clawdroid.local")
            setRequestProperty("X-Title", "ClawDroid")
        }

        connection.outputStream.use { output ->
            output.write(payload.toString().toByteArray(Charsets.UTF_8))
        }

        val responseText = if (connection.responseCode in 200..299) {
            connection.inputStream.bufferedReader().use { it.readText() }
        } else {
            val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            error("LLM HTTP ${connection.responseCode}: $errorText")
        }

        val response = JSONObject(responseText)
        val content = response
            .getJSONArray("choices")
            .getJSONObject(0)
            .getJSONObject("message")
            .optString("content")
            .trim()

        check(content.isNotBlank()) { "LLM returned an empty message" }
        ModelTestResult(model = model, content = content)
    }

    suspend fun runStreamingSmokeTest(): ModelTestResult {
        val text = StringBuilder()
        LlmApiClient().streamChat(
            messages = listOf(
                ChatMessage(
                    role = "system",
                    content = "Reply with one short sentence.",
                ),
                ChatMessage(
                    role = "user",
                    content = "Say ClawDroid streaming smoke test ok.",
                ),
            )
        ).collect { event ->
            when (event) {
                is StreamEvent.TextDelta -> text.append(event.text)
                is StreamEvent.ToolCallDeltaReceived -> Unit
                is StreamEvent.Error -> error(event.message)
                is StreamEvent.ToolCallComplete -> Unit
                is StreamEvent.Usage -> Unit
                StreamEvent.Done -> Unit
            }
        }

        val content = text.toString().trim()
        check(content.isNotBlank()) { "LLM stream returned an empty message" }
        return ModelTestResult(model = BuildConfig.LLM_MODEL, content = content)
    }
}
