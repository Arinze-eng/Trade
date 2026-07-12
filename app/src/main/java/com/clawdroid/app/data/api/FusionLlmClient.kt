package com.clawdroid.app.data.api

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray

/**
 * FusionLlmClient — the INBUILT, keyless multi-racer FUSION brain for ClawDroid.
 *
 * This is the "HotBot / Gemini / racers FUSION". Instead of talking to a single
 * gateway, it now runs a SMART-ROUTED PANEL of keyless racers (Gemini gateway,
 * Pollinations, eqing, and optionally StudentAI / Novita) as a lightweight
 * Mixture-of-Agents and returns the FIRST solid answer / tool-call — so the
 * agent is fast, resilient, and never blocked by one provider being down or
 * rate-limited.
 *
 * SMART ROUTING (see [FusionRacers]):
 *   - Requests WITH an image/file → only multimodal racers (Gemini, Novita).
 *   - TEXT-only requests          → text racers (Pollinations, eqing, StudentAI) + Gemini.
 *   - Tool-step turns             → only tool-capable racers.
 * For files a text-only racer cannot read (PDF/scanned image), the agent runs
 * OCR in the sandbox first (see the ocr_extract tool) and feeds the extracted
 * text, so every racer can still contribute.
 *
 * The multi-racer result is translated back into ClawDroid's OpenAI-style
 * [StreamEvent]s (TextDelta / ToolCallComplete / Usage / Done), so the existing
 * AgentEngine works completely unchanged.
 */
class FusionLlmClient {

    companion object {
        const val PROVIDER = "fusion"
        const val BASE_URL = "https://gemini-gateway.huymq-it.workers.dev"
        const val MODEL_LABEL = "fusion-racers"

        /** True if the given base URL / provider selects the inbuilt FUSION brain. */
        fun isFusion(baseUrl: String, provider: String): Boolean {
            return provider.equals(PROVIDER, ignoreCase = true) ||
                baseUrl.contains("gemini-gateway", ignoreCase = true) ||
                baseUrl.equals("fusion", ignoreCase = true) ||
                baseUrl.equals("inbuilt", ignoreCase = true)
        }

        /** Expose the packed thoughtSignature decoder for callers replaying history. */
        fun decodeSignature(id: String): String? = GeminiPayloadBuilder.decodeSignature(id)

        const val FUSION_SYSTEM = """You are the ClawDroid FUSION brain — a Captain-class autonomous agent that fuses the strengths of HotBot GPT-5, Gemini, DeepSeek and multiple keyless racers (Pollinations, eqing, StudentAI, Novita) into one powerful in-app intelligence.

CORE RULES:
1. WORKING AGENT, NOT CHATBOT. You DO things — call tools, write real code, produce real output. Never say "here's how you'd do it" — do it.
2. COMPLETE ANSWERS ONLY. No stubs, no "...", no placeholders. Every answer is ready to use.
3. USE TOOLS DECISIVELY. When a tool is available and relevant, call it. Return exactly one clear next action per step.
4. VERIFY BEFORE FINISHING. Check your work mentally before declaring done.
5. NEVER LOOP. If an approach fails twice, change approach.
6. FILES: To read PDFs, scanned images, spreadsheets or archives, use the sandbox — run `ocr_extract` for images/PDF text, `unzip`/`tar` for archives, and standard CLI tools (pdftotext, tesseract, unzip, file). Process any uploaded file and return the result.
7. IMAGES: To create an image, call the generate_image tool.
8. LANGUAGE: English only unless the user writes in another language."""

        // Fusion tuning (kept small for low latency + low data use on mobile).
        private const val FIRST_WAVE = 2      // racers launched in the first wave
        private const val RACE_TIMEOUT_MS = 45_000L
    }

    /**
     * Stream a chat completion from the inbuilt multi-racer FUSION brain,
     * translating to ClawDroid's OpenAI-style [StreamEvent] contract.
     */
    fun streamChat(
        messages: List<ChatMessage>,
        tools: JSONArray? = null,
        forcedToolName: String? = null,
    ): Flow<StreamEvent> = flow {
        val hasMedia = FusionRacers.requestHasMedia(messages)
        val needsTools = tools != null && tools.length() > 0
        val panel = FusionRacers.selectRacers(hasMedia = hasMedia, needsTools = false)
        Log.i(
            "FusionLlmClient",
            "FUSION streamChat: msgs=${messages.size} tools=${tools?.length() ?: 0} " +
                "media=$hasMedia panel=[${panel.joinToString(",") { it.label }}]"
        )

        if (panel.isEmpty()) {
            emit(StreamEvent.Error("FUSION: no racer available for this request"))
            return@flow
        }

        // Split the panel into an ordered fallback chain. We try racers in order,
        // launching the strongest first; the FIRST usable result wins. This keeps
        // latency and data use low (we don't wait for every brain), while still
        // giving resilience: if one racer fails we immediately try the next.
        var result: FusionRacers.RacerResult? = null
        val errors = StringBuilder()

        for (racer in panel) {
            // Tool turns must use a tool-capable racer; skip ones that can't.
            if (needsTools && !racer.supportsTools) continue
            val r = runCatching {
                withTimeoutBlocking(RACE_TIMEOUT_MS) {
                    racer.call(messages, tools, forcedToolName)
                }
            }.getOrElse { e ->
                errors.append(racer.label).append(": ").append(e.message ?: e.toString()).append(" | ")
                Log.w("FusionLlmClient", "racer ${racer.label} failed: ${e.message}")
                null
            }
            if (r != null && r.isUsable) {
                Log.i("FusionLlmClient", "FUSION winner: ${racer.label}")
                result = r
                break
            }
        }

        if (result == null) {
            emit(StreamEvent.Error("FUSION: all racers failed (${errors.toString().take(300)})"))
            return@flow
        }

        // Emit tool calls first, then text (matches OpenAI ordering expectations).
        result.toolCalls.forEach { emit(StreamEvent.ToolCallComplete(it)) }
        if (result.text.isNotEmpty()) emit(StreamEvent.TextDelta(result.text))
        if (result.promptTokens > 0 || result.completionTokens > 0) {
            emit(
                StreamEvent.Usage(
                    TokenUsage(
                        promptTokens = result.promptTokens,
                        completionTokens = result.completionTokens,
                        cachedTokens = 0,
                    )
                )
            )
        }
        if (result.toolCalls.isEmpty() && result.text.isEmpty()) {
            emit(StreamEvent.TextDelta(""))
        }
        emit(StreamEvent.Done)
    }.flowOn(Dispatchers.IO)

    /** Run a blocking racer call with a hard timeout on the current IO thread. */
    private fun <T> withTimeoutBlocking(timeoutMs: Long, block: () -> T): T {
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit(java.util.concurrent.Callable { block() })
            return future.get(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (e: java.util.concurrent.TimeoutException) {
            throw RuntimeException("racer timed out after ${timeoutMs}ms")
        } catch (e: java.util.concurrent.ExecutionException) {
            throw (e.cause ?: e)
        } finally {
            executor.shutdownNow()
        }
    }
}
