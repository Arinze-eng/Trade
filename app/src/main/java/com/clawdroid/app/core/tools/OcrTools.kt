package com.clawdroid.app.core.tools

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * OcrTools — extract text from images, PDFs, and archives using the sandbox.
 *
 * This is the "OCR fallback" that lets ANY racer (even text-only ones like eqing)
 * work with uploaded files: the agent runs ocr_extract, we return the extracted
 * plain text, and that text is fed to the model as normal context.
 *
 * Strategy by file type (all run inside the Termux/Linux sandbox):
 *   - .pdf                      → pdftotext (poppler); OCR fallback for scanned PDFs.
 *   - .png/.jpg/.jpeg/.webp/... → tesseract OCR.
 *   - .zip                      → unzip -l (list) or full extract on request.
 *   - .tar/.gz/.tgz             → tar listing / extract.
 *   - .txt/.md/.csv/.json/...   → plain read (head).
 * Required CLI tools are auto-installed via apt/pkg on first use.
 */
object OcrTools {

    suspend fun extract(
        context: Context,
        path: String,
        cwd: String? = null,
        maxChars: Int = 20_000,
    ): JSONObject {
        require(path.isNotBlank()) { "path is required" }
        val ext = File(path).extension.lowercase()
        val quoted = shellQuote(path)

        val command = when (ext) {
            "pdf" -> buildString {
                // Ensure poppler + tesseract available (idempotent, quiet).
                append(ensure("pdftotext", "poppler-utils"))
                append(ensure("tesseract", "tesseract"))
                // Try text layer first; if empty, OCR each rendered page.
                append("txt=$(pdftotext -q $quoted - 2>/dev/null); ")
                append("if [ -n \"\$txt\" ]; then printf '%s' \"\$txt\"; ")
                append("else ")
                append(ensure("pdftoppm", "poppler-utils"))
                append("tmpd=$(mktemp -d); pdftoppm -r 200 -png $quoted \"\$tmpd/pg\" >/dev/null 2>&1; ")
                append("for f in \"\$tmpd\"/pg*.png; do tesseract \"\$f\" stdout 2>/dev/null; done; ")
                append("rm -rf \"\$tmpd\"; fi")
            }
            "png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "gif" -> buildString {
                append(ensure("tesseract", "tesseract"))
                append("tesseract $quoted stdout 2>/dev/null")
            }
            "zip" -> buildString {
                append(ensure("unzip", "unzip"))
                append("echo '--- ZIP CONTENTS ---'; unzip -l $quoted")
            }
            "tar", "gz", "tgz", "bz2", "xz" -> "echo '--- ARCHIVE CONTENTS ---'; tar -tf $quoted 2>/dev/null || (echo '(not a tar; trying gzip)'; zcat $quoted 2>/dev/null | head -c 4000)"
            "docx", "pptx", "xlsx" -> buildString {
                // Office files are zip archives of XML — extract visible text.
                append(ensure("unzip", "unzip"))
                append("unzip -p $quoted '*.xml' 2>/dev/null | sed -e 's/<[^>]*>/ /g' | tr -s ' ' | head -c 20000")
            }
            else -> "head -c $maxChars $quoted"
        }

        val result = CommandTool.execute(
            context = context,
            command = command,
            cwd = cwd,
            // OCR + first-time apt install can be slow; give it room but bounded.
            timeoutSeconds = 240,
        )
        val text = result.output.trim().take(maxChars)
        return JSONObject()
            .put("path", path)
            .put("type", ext.ifBlank { "unknown" })
            .put("chars", text.length)
            .put("text", text.ifBlank { "(no extractable text found)" })
            .put("exit_code", result.exitCode)
    }

    /** Extract a full archive into a target dir (for the sandbox to process files). */
    suspend fun unpack(
        context: Context,
        path: String,
        dest: String? = null,
        cwd: String? = null,
    ): JSONObject {
        require(path.isNotBlank()) { "path is required" }
        val ext = File(path).extension.lowercase()
        val quoted = shellQuote(path)
        val destDir = dest?.takeIf { it.isNotBlank() } ?: (File(path).nameWithoutExtension + "_extracted")
        val quotedDest = shellQuote(destDir)
        val command = when (ext) {
            "zip", "docx", "pptx", "xlsx" -> ensure("unzip", "unzip") +
                "mkdir -p $quotedDest && unzip -o $quoted -d $quotedDest && echo '--- EXTRACTED ---' && find $quotedDest -maxdepth 2 -type f | head -100"
            "tar" -> "mkdir -p $quotedDest && tar -xf $quoted -C $quotedDest && find $quotedDest -maxdepth 2 -type f | head -100"
            "gz", "tgz" -> "mkdir -p $quotedDest && tar -xzf $quoted -C $quotedDest && find $quotedDest -maxdepth 2 -type f | head -100"
            "bz2" -> "mkdir -p $quotedDest && tar -xjf $quoted -C $quotedDest && find $quotedDest -maxdepth 2 -type f | head -100"
            "xz" -> "mkdir -p $quotedDest && tar -xJf $quoted -C $quotedDest && find $quotedDest -maxdepth 2 -type f | head -100"
            else -> throw IllegalArgumentException("Unsupported archive type: .$ext")
        }
        val result = CommandTool.execute(context, command, cwd, timeoutSeconds = 240)
        return JSONObject()
            .put("path", path)
            .put("dest", destDir)
            .put("output", result.output.trim().take(8000))
            .put("exit_code", result.exitCode)
    }

    /**
     * Emit a shell snippet that installs [bin] via apt/pkg if it's missing.
     * Idempotent and quiet — safe to prepend to any command.
     */
    private fun ensure(bin: String, pkg: String): String =
        "command -v $bin >/dev/null 2>&1 || { " +
            "(apt-get install -y $pkg >/dev/null 2>&1) || (pkg install -y $pkg >/dev/null 2>&1) || " +
            "(apt-get update >/dev/null 2>&1 && apt-get install -y $pkg >/dev/null 2>&1); }; "

    private fun shellQuote(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}
