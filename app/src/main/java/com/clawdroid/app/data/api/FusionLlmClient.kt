package com.clawdroid.app.data.api

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * FusionLlmClient — the INBUILT, keyless FUSION brain for ClawDroid.
 *
 * This is the "HotBot / Gemini / racers FUSION" inbuilt LLM. It talks to the
 * keyless Gemini gateway (reverse-engineered, Bearer 12345678) which serves
 * gemini-3.1-flash-lite server-side. No API key, no signup, no per-user config.
 *
 * It fully supports the agent ReAct loop: OpenAI-style messages + tools are
 * translated to the native Gemini generateContent format, and the Gemini
 * response (text + functionCall parts) is translated back into ClawDroid's
 * OpenAI-style [StreamEvent]s (TextDelta / ToolCallComplete / Usage / Done),
 * so the existing AgentEngine works unchanged.
 *
 * Because the gateway is non-streaming, we buffer the full response and emit it
 * as a single TextDelta (plus any tool calls). The agent loop treats this
 * identically to a streamed OpenAI reply.
 */
class FusionLlmClient {

    companion object {
        const val PROVIDER = "fusion"
        const val BASE_URL = "https://gemini-gateway.huymq-it.workers.dev"
        private const val ENDPOINT = "/api/generate"
        private const val AUTH_TOKEN = "Bearer 12345678"
        const val MODEL_LABEL = "fusion-gemini-3.1"

        /** True if the given base URL / provider selects the inbuilt FUSION brain. */
        fun isFusion(baseUrl: String, provider: String): Boolean {
            return provider.equals(PROVIDER, ignoreCase = true) ||
                baseUrl.contains("gemini-gateway", ignoreCase = true) ||
                baseUrl.equals("fusion", ignoreCase = true) ||
                baseUrl.equals("inbuilt", ignoreCase = true)
        }

        /**
         * The FUSION system directive. Makes the inbuilt brain a strong,
         * complete-answer autonomous agent (never refuses, never stubs, always
         * finishes the deliverable). Prepended to whatever system prompt the
         * agent supplies.
         */
        const val FUSION_SYSTEM = """You are the ClawDroid FUSION brain — a Captain-class autonomous agent that fuses the strengths of HotBot GPT-5, Gemini, DeepSeek and multiple keyless racers into one powerful in-app intelligence.

CORE RULES:
1. WORKING AGENT, NOT CHATBOT. You DO things — call tools, write real code, produce real output. Never say "here's how you'd do it" — do it.
2. COMPLETE ANSWERS ONLY. No stubs, no "...", no placeholders. Every answer is ready to use.
3. USE TOOLS DECISIVELY. When a tool is available and relevant, call it. Return exactly one clear next action per step.
4. VERIFY BEFORE FINISHING. Check your work mentally before declaring done.
5. NEVER LOOP. If an approach fails twice, change approach.
6. LANGUAGE: English only unless the user writes in another language."""
    }

    /**
     * Stream a chat completion from the inbuilt FUSION brain, translating to
     * ClawDroid's OpenAI-style [StreamEvent] contract (text + tool calls).
     */
    fun streamChat(
        messages: List<ChatMessage>,
        tools: JSONArray? = null,
        forcedToolName: String? = null,
    ): Flow<StreamEvent> = flow {
        Log.i("FusionLlmClient", "FUSION streamChat: messages=${messages.size}, tools=${tools?.length() ?: 0}")

        val payload = buildGeminiPayload(messages, tools, forcedToolName)

        val connection = (URL("$BASE_URL$ENDPOINT").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 20_000
            readTimeout = 120_000
            doOutput = true
            setRequestProperty("Authorization", AUTH_TOKEN)
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Accept", "application/json")
        }

        connection.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }

        val code = connection.responseCode
        Log.i("FusionLlmClient", "FUSION response code: $code")
        if (code !in 200..299) {
            val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            Log.e("FusionLlmClient", "FUSION HTTP error $code: $errorText")
            emit(StreamEvent.Error("FUSION HTTP $code: ${errorText.take(300)}"))
            return@flow
        }

        val responseText = connection.inputStream.bufferedReader().use { it.readText() }
        val root = runCatching { JSONObject(responseText) }.getOrNull()
        if (root == null) {
            emit(StreamEvent.Error("FUSION: unparseable response"))
            return@flow
        }

        val candidate = root.optJSONArray("candidates")?.optJSONObject(0)
        val parts = candidate?.optJSONObject("content")?.optJSONArray("parts")

        var emittedAnything = false
        if (parts != null) {
            for (i in 0 until parts.length()) {
                val part = parts.optJSONObject(i) ?: continue

                // Function call → OpenAI tool call
                val fnCall = part.optJSONObject("functionCall")
                if (fnCall != null) {
                    val name = fnCall.optString("name")
                    val args = fnCall.optJSONObject("args") ?: JSONObject()
                    val id = fnCall.optString("id").takeIf { it.isNotBlank() }
                        ?: ("call_" + UUID.randomUUID().toString().replace("-", "").take(12))
                    emit(
                        StreamEvent.ToolCallComplete(
                            CompletedToolCall(id = id, name = name, arguments = args.toString())
                        )
                    )
                    emittedAnything = true
                    continue
                }

                // Text → text delta
                val text = part.optString("text")
                if (text.isNotEmpty()) {
                    emit(StreamEvent.TextDelta(text))
                    emittedAnything = true
                }
            }
        }

        // Usage
        val usage = root.optJSONObject("usageMetadata")
        if (usage != null) {
            emit(
                StreamEvent.Usage(
                    TokenUsage(
                        promptTokens = usage.optInt("promptTokenCount", 0),
                        completionTokens = usage.optInt("candidatesTokenCount", 0),
                        cachedTokens = 0,
                    )
                )
            )
        }

        if (!emittedAnything) {
            emit(StreamEvent.TextDelta(""))
        }
        emit(StreamEvent.Done)
    }.flowOn(Dispatchers.IO)

    /** Build the native Gemini generateContent payload from OpenAI-style inputs. */
    private fun buildGeminiPayload(
        messages: List<ChatMessage>,
        tools: JSONArray?,
        forcedToolName: String?,
    ): JSONObject {
        // System instruction = FUSION_SYSTEM + any system messages merged.
        val systemText = buildString {
            append(FUSION_SYSTEM)
            messages.filter { it.role == "system" && !it.content.isNullOrBlank() }
                .forEach { append("\n\n").append(it.content) }
        }

        val contents = JSONArray()
        for (message in messages) {
            when (message.role) {
                "system" -> { /* folded into system_instruction */ }
                "tool" -> {
                    // Tool result → Gemini functionResponse part
                    val fnResponse = JSONObject()
                        .put("name", message.toolCallId ?: "tool")
                        .put(
                            "response",
                            JSONObject().put("result", message.content ?: "")
                        )
                    contents.put(
                        JSONObject()
                            .put("role", "user")
                            .put(
                                "parts",
                                JSONArray().put(JSONObject().put("functionResponse", fnResponse))
                            )
                    )
                }
                "assistant" -> {
                    val partsArr = JSONArray()
                    if (!message.content.isNullOrBlank()) {
                        partsArr.put(JSONObject().put("text", message.content))
                    }
                    message.toolCalls.forEach { call ->
                        val argsObj = runCatching { JSONObject(call.arguments) }
                            .getOrElse { JSONObject() }
                        partsArr.put(
                            JSONObject().put(
                                "functionCall",
                                JSONObject().put("name", call.name).put("args", argsObj)
                            )
                        )
                    }
                    if (partsArr.length() > 0) {
                        contents.put(JSONObject().put("role", "model").put("parts", partsArr))
                    }
                }
                else -> {
                    // user
                    val partsArr = JSONArray()
                    if (!message.content.isNullOrBlank()) {
                        partsArr.put(JSONObject().put("text", message.content))
                    }
                    // Inline image support (base64) for multimodal user turns
                    if (message.mediaPath != null && message.mediaMimeType != null) {
                        val file = java.io.File(message.mediaPath)
                        if (file.exists() && file.isFile) {
                            val base64 = android.util.Base64.encodeToString(
                                file.readBytes(), android.util.Base64.NO_WRAP
                            )
                            partsArr.put(
                                JSONObject().put(
                                    "inline_data",
                                    JSONObject()
                                        .put("mime_type", message.mediaMimeType)
                                        .put("data", base64)
                                )
                            )
                        }
                    }
                    if (partsArr.length() == 0) {
                        partsArr.put(JSONObject().put("text", ""))
                    }
                    contents.put(JSONObject().put("role", "user").put("parts", partsArr))
                }
            }
        }

        val payload = JSONObject()
            .put("system_instruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", systemText))))
            .put("contents", contents)

        // Translate OpenAI tools → Gemini functionDeclarations
        if (tools != null && tools.length() > 0) {
            val declarations = JSONArray()
            for (i in 0 until tools.length()) {
                val fn = tools.optJSONObject(i)?.optJSONObject("function") ?: continue
                val decl = JSONObject()
                    .put("name", fn.optString("name"))
                    .put("description", fn.optString("description"))
                val params = fn.optJSONObject("parameters")
                if (params != null) decl.put("parameters", sanitizeSchema(params))
                declarations.put(decl)
            }
            if (declarations.length() > 0) {
                payload.put("tools", JSONArray().put(JSONObject().put("functionDeclarations", declarations)))

                // Forced tool → Gemini toolConfig ANY mode with allowed name
                if (!forcedToolName.isNullOrBlank()) {
                    payload.put(
                        "tool_config",
                        JSONObject().put(
                            "function_calling_config",
                            JSONObject()
                                .put("mode", "ANY")
                                .put("allowed_function_names", JSONArray().put(forcedToolName))
                        )
                    )
                }
            }
        }

        return payload
    }

    /**
     * Gemini's schema validator rejects some JSON-Schema keywords that OpenAI
     * tools commonly include (e.g. additionalProperties, $schema, default).
     * Strip anything Gemini doesn't accept, recursively.
     */
    private fun sanitizeSchema(schema: JSONObject): JSONObject {
        val allowed = setOf(
            "type", "description", "properties", "items", "required",
            "enum", "format", "nullable"
        )
        val out = JSONObject()
        val keys = schema.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (key !in allowed) continue
            val value = schema.get(key)
            when {
                key == "properties" && value is JSONObject -> {
                    val props = JSONObject()
                    val pk = value.keys()
                    while (pk.hasNext()) {
                        val propName = pk.next()
                        val propVal = value.get(propName)
                        if (propVal is JSONObject) {
                            props.put(propName, sanitizeSchema(propVal))
                        } else {
                            props.put(propName, propVal)
                        }
                    }
                    out.put(key, props)
                }
                key == "items" && value is JSONObject -> out.put(key, sanitizeSchema(value))
                else -> out.put(key, value)
            }
        }
        // Gemini requires "type" on every schema node; default to object.
        if (!out.has("type")) out.put("type", "object")
        return out
    }
}
