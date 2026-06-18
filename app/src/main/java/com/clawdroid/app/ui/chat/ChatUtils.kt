package com.clawdroid.app.ui.chat

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.drawable.toBitmap
import androidx.compose.ui.platform.LocalContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * Copy a URI to a local cache file and return the File.
 */
fun copyUriToCache(context: Context, uri: Uri): File? {
    return try {
        val cursor = context.contentResolver.query(uri, null, null, null, null)
        val nameIndex = cursor?.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        cursor?.moveToFirst()
        val fileName = if (nameIndex != null && nameIndex >= 0) {
            cursor?.getString(nameIndex) ?: "cached_file_${System.currentTimeMillis()}"
        } else {
            "cached_file_${System.currentTimeMillis()}"
        }
        cursor?.close()

        val cacheFile = File(context.cacheDir, fileName)
        context.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(cacheFile).use { output ->
                input.copyTo(output)
            }
        }
        cacheFile
    } catch (e: Exception) {
        null
    }
}

/**
 * Extract a JSON field from a possibly-malformed JSON string.
 */
fun extractJsonField(json: String, field: String): String? {
    return try {
        // Try direct JSON parsing first
        val obj = JSONObject(json)
        if (obj.has(field)) obj.optString(field) else null
    } catch (e: Exception) {
        // Fallback: regex extraction for malformed JSON
        val regex = Regex("\"$field\"\\s*:\\s*\"([^\"]*)\"")
        regex.find(json)?.groupValues?.getOrNull(1)
    }
}

/**
 * Convert a tool name (snake_case) to a human-readable name.
 */
fun String.readableToolName(): String {
    return this
        .replace("_", " ")
        .split(" ")
        .joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }
}

/**
 * Convert a tool name to an ActivityStepType string.
 */
fun String.toActivityStepType(): String {
    return when {
        this.contains("write") || this.contains("file") -> "file_write"
        this.contains("read") || this.contains("search") -> "search"
        this.contains("edit") -> "file_edit"
        this.contains("terminal") || this.contains("command") || this.contains("exec") -> "command"
        this.contains("web") || this.contains("browse") || this.contains("http") -> "web"
        this.contains("think") || this.contains("reason") -> "think"
        else -> "tool"
    }
}

/**
 * Format byte count to human-readable string.
 */
fun formatBytes(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        bytes < 1024 * 1024 * 1024 -> "${"%.1f".format(bytes.toDouble() / (1024 * 1024))} MB"
        else -> "${"%.2f".format(bytes.toDouble() / (1024 * 1024 * 1024))} GB"
    }
}

/**
 * Format diff text for display in chat.
 */
fun formatDiffDisplayText(text: String): String {
    if (text.length <= 200) return text
    return text.take(200) + "..."
}

/**
 * Load a bitmap from URI (Composable-friendly).
 */
@Composable
fun rememberBitmapFromUri(uri: Uri?): ImageBitmap? {
    val context = LocalContext.current
    return remember(uri) {
        if (uri == null) null
        else try {
            val inputStream = context.contentResolver.openInputStream(uri)
            val bitmap = android.graphics.BitmapFactory.decodeStream(inputStream)
            inputStream?.close()
            bitmap?.asImageBitmap()
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * Build file preview data from a list of items.
 */
fun buildFilePreviews(items: List<Any>): List<FilePreviewData> {
    return items.mapNotNull { item ->
        when (item) {
            is String -> FilePreviewData(
                name = item.substringAfterLast("/").substringAfterLast("\\"),
                type = item.substringAfterLast(".").take(10),
                preview = item
            )
            else -> null
        }
    }
}

data class FilePreviewData(
    val name: String,
    val type: String,
    val preview: String
)

/**
 * Get metadata (size, type, name) for a URI.
 */
data class UriMetadata(val name: String, val size: Long, val mimeType: String)

fun getUriMetadata(context: Context, uri: Uri): UriMetadata? {
    return try {
        val cursor = context.contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val nameIdx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = it.getColumnIndex(OpenableColumns.SIZE)
                val name = if (nameIdx >= 0) it.getString(nameIdx) else "unknown"
                val size = if (sizeIdx >= 0) it.getLong(sizeIdx) else 0L
                val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
                UriMetadata(name, size, mime)
            } else null
        }
    } catch (e: Exception) {
        null
    }
}
