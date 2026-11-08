package app.shuyu.reader

import android.content.Context
import android.graphics.BitmapFactory
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mewx.wenku8.api.TokenManager
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

/** Bounded I/O workers for guest discovery/search, cover, and illustration requests. */
internal class Wenku8Bridge(context: Context, private val postToMain: (Runnable) -> Unit) : MethodChannel.MethodCallHandler {
    private val io = Executors.newFixedThreadPool(4)
    private val imageIo = Executors.newSingleThreadExecutor()
    private val images = File(context.filesDir, "wenku8-illustrations-v1")
    private val imageLock = Any()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("request", "cover", "illustration")) {
            result.notImplemented()
            return
        }
        (if (call.method == "illustration") imageIo else io).execute {
            try {
                val response: Any = when (call.method) {
                    "illustration" -> illustration(call.argument<String>("url") ?: "")
                    else -> {
                        val action = if (call.method == "cover") {
                            val id = call.argument<Int>("aid") ?: 0
                            require(id > 0)
                            "action=book&do=cover&aid=$id"
                        } else call.argument<String>("action") ?: ""
                        require(action.isNotBlank() && action.length <= 60000)
                        val bytes = request(action)
                        if (call.method == "request") bytes.toString(Charsets.UTF_8) else bytes
                    }
                }
                postToMain(Runnable { result.success(response) })
            } catch (_: Exception) {
                postToMain(Runnable { result.error("LEGACY_API_ERROR", "Request or local storage failed", null) })
            } catch (_: LinkageError) {
                postToMain(Runnable { result.error("LEGACY_API_RUNTIME", "Legacy runtime unavailable", null) })
            }
        }
    }

    private fun request(action: String): ByteArray {
        val version = TokenManager.getMagicVersionCpp("1.30")
        val encoded = Base64.encodeToString(action.toByteArray(Charsets.UTF_8), Base64.DEFAULT).trim()
        val body = "&appver=$version&request=$encoded&timetoken=${System.currentTimeMillis()}"
        val connection = (URL("https://wenku8-relay.mewx.org/").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Accept-Encoding", "gzip")
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
            connectTimeout = 5000
            readTimeout = 10000
            doOutput = true
            instanceFollowRedirects = false
        }
        try {
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            check(connection.responseCode in 200..299)
            val stream = if (connection.contentEncoding?.contains("gzip", ignoreCase = true) == true) {
                GZIPInputStream(BufferedInputStream(connection.inputStream))
            } else connection.inputStream
            return stream.use { readBounded(it, 8 * 1024 * 1024) }
        } finally {
            connection.disconnect()
        }
    }

    private fun illustration(raw: String): ByteArray = synchronized(imageLock) {
        val url = IllustrationUrlPolicy.parse(raw)
        val name = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(images, name)
        if (file.isFile) {
            try {
                require(file.length() in 1..(8 * 1024 * 1024))
                val cached = file.readBytes()
                validateImage(cached)
                file.setLastModified(System.currentTimeMillis())
                return@synchronized cached
            } catch (_: Exception) { file.delete() }
        }
        val bytes = downloadIllustration(url)
        try {
            images.mkdirs()
            val temporary = File(images, "$name.part")
            temporary.writeBytes(bytes)
            check(temporary.renameTo(file))
            val cached = images.listFiles()?.filter { it.isFile } ?: emptyList()
            var size = cached.sumOf { it.length() }
            for (old in cached.sortedBy { it.lastModified() }) {
                if (size <= 256L * 1024 * 1024) break
                if (old != file) { val length = old.length(); if (old.delete()) size -= length }
            }
        } catch (_: Exception) { /* An online illustration survives a cache write error. */ }
        bytes
    }

    private fun downloadIllustration(source: URL): ByteArray {
        var url = source
        for (hop in 0..3) {
            val connection = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 12000
                instanceFollowRedirects = false
            }
            try {
                val status = connection.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    check(hop < 3) { "Too many image redirects" }
                    val location = connection.getHeaderField("Location")
                    require(!location.isNullOrBlank())
                    url = IllustrationUrlPolicy.redirect(url, location)
                } else {
                    check(status in 200..299)
                    val bytes = connection.inputStream.use { readBounded(it, 8 * 1024 * 1024) }
                    validateImage(bytes)
                    return bytes
                }
            } finally {
                connection.disconnect()
            }
        }
        error("Image redirect limit")
    }

    private fun validateImage(bytes: ByteArray) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0 &&
            bounds.outWidth <= 16384 && bounds.outHeight <= 16384 &&
            bounds.outWidth.toLong() * bounds.outHeight <= 12_000_000L)
    }

    private fun readBounded(input: java.io.InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit)
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
    fun close() {
        io.shutdown()
        imageIo.shutdown()
    }
}
