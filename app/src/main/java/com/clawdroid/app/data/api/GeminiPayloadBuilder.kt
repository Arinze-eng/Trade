package com.clawdroid.app.data.api

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * GeminiPayloadBuilder — shared translation between ClawDroid's OpenAI-style
 * [ChatMessage] / tool contract and the native Gemini generateContent format.
 *
 * Extracted from FusionLlmClient so both the single-brain fusion path AND the
 * multi-racer [FusionRacers] roster can reuse the exact same, battle-tested
 * translation (including the Gemini 3.x thoughtSignature packing).
 */
object GeminiPayloadBuilder {

    private const val SIG_DELIM = "::sig::"

    fun encodeId(id: String, signature: String?): String =
        if (signature.isNullOrBlank()) id else id + SIG_DELIM + signature

    fun decodeSignature(id: String): String? {
        val idx = id.indexOf(SIG_DELIM)
        return if (idx >= 0) id.substring(idx + SIG_DELIM.length).takeIf { it.isNotBlank() } else null
    }

    /** Build the native Gemini generateContent payload from OpenAI-style inputs. */
    fun build(
        messages: List<ChatMessage>,
        tools: JSONArray?,
        forcedToolName: String?,
    ): JSONObject {
        val systemText = buildString {
            append(FusionLlmClient.FUSION_SYSTEM)
            messages.filter { it.role == "system" && !it.content.isNullOrBlank() }
                .forEach { append("\n\n").append(it.content) }
        }

        val contents = JSONArray()
        val callIdToName = HashMap<String, String>()
        messages.forEach { m -> m.toolCalls.forEach { c -> callIdToName[c.id] = c.name } }

        for (message in messages) {
            when (message.role) {
                "system" -> { /* folded into system_instruction */ }
                "tool" -> {
                    val fnName = message.toolCallId?.let { callIdToName[it] } ?: "tool"
                    val fnResponse = JSONObject()
                        .put("name", fnName)
                        .put("response", JSONObject().put("result", message.content ?: ""))
                    contents.put(
                        JSONObject().put("role", "user").put(
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
                        val argsObj = runCatching { JSONObject(call.arguments) }.getOrElse { JSONObject() }
                        val fnCallObj = JSONObject().put("name", call.name).put("args", argsObj)
                        val part = JSONObject().put("functionCall", fnCallObj)
                        decodeSignature(call.id)?.let { sig -> part.put("thoughtSignature", sig) }
                        partsArr.put(part)
                    }
                    if (partsArr.length() > 0) {
                        contents.put(JSONObject().put("role", "model").put("parts", partsArr))
                    }
                }
                else -> {
                    val partsArr = JSONArray()
                    if (!message.content.isNullOrBlank()) {
                        partsArr.put(JSONObject().put("text", message.content))
                    }
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
                    if (partsArr.length() == 0) partsArr.put(JSONObject().put("text", ""))
                    contents.put(JSONObject().put("role", "user").put("parts", partsArr))
                }
            }
        }

        val payload = JSONObject()
            .put("system_instruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", systemText))))
            .put("contents", contents)

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

    /** Parse a Gemini generateContent response into a [FusionRacers.RacerResult]. */
    fun parse(raw: String): FusionRacers.RacerResult {
        val root = JSONObject(raw)
        val candidate = root.optJSONArray("candidates")?.optJSONObject(0)
        val parts = candidate?.optJSONObject("content")?.optJSONArray("parts")
        val sb = StringBuilder()
        val toolCalls = mutableListOf<CompletedToolCall>()
        if (parts != null) {
            for (i in 0 until parts.length()) {
                val part = parts.optJSONObject(i) ?: continue
                val fnCall = part.optJSONObject("functionCall")
                if (fnCall != null) {
                    val name = fnCall.optString("name")
                    val args = fnCall.optJSONObject("args") ?: JSONObject()
                    val rawId = fnCall.optString("id").takeIf { it.isNotBlank() }
                        ?: ("call_" + UUID.randomUUID().toString().replace("-", "").take(12))
                    val signature = part.optString("thoughtSignature").takeIf { it.isNotBlank() }
                    toolCalls.add(CompletedToolCall(encodeId(rawId, signature), name, args.toString()))
                    continue
                }
                val text = part.optString("text")
                if (text.isNotEmpty()) sb.append(text)
            }
        }
        val usage = root.optJSONObject("usageMetadata")
        return FusionRacers.RacerResult(
            text = sb.toString(),
            toolCalls = toolCalls,
            promptTokens = usage?.optInt("promptTokenCount", 0) ?: 0,
            completionTokens = usage?.optInt("candidatesTokenCount", 0) ?: 0,
        )
    }

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
                        if (propVal is JSONObject) props.put(propName, sanitizeSchema(propVal))
                        else props.put(propName, propVal)
                    }
                    out.put(key, props)
                }
                key == "items" && value is JSONObject -> out.put(key, sanitizeSchema(value))
                else -> out.put(key, value)
            }
        }
        if (!out.has("type")) out.put("type", "object")
        return out
    }
}
