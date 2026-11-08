package app.shuyu.reader

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/** Keep original encoded pixels; exporting never recompresses a book image. */
internal object BookImageStore {
    data class Image(val bytes: ByteArray, val mime: String, val name: String)
    fun renderedImage(bytes: ByteArray?, name: String?): Image {
        require(QuoteCardImage.valid(bytes)) { "图片格式或大小无效" }
        return Image(bytes!!, "image/png", QuoteCardImage.fileName(name))
    }

    fun save(context: Context, image: Image) {
        val resolver = context.contentResolver
        // Before scoped storage, a granted WRITE_EXTERNAL_STORAGE permission
        // allows a normal Pictures file. A unique file never replaces an image.
        val legacyFile = if (Build.VERSION.SDK_INT < 29) {
            @Suppress("DEPRECATION")
            val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Wenku8")
            check(directory.isDirectory || directory.mkdirs()) { "无法创建相册目录" }
            val extension = image.name.substringAfterLast('.', "png")
            File.createTempFile(image.name.substringBeforeLast('.').take(80).padEnd(3, '-'), ".$extension", directory)
        } else null
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, image.name)
            put(MediaStore.Images.Media.MIME_TYPE, image.mime)
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Wenku8")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            } else {
                @Suppress("DEPRECATION")
                put(MediaStore.Images.Media.DATA, checkNotNull(legacyFile).absolutePath)
            }
        }
        try {
            commitGalleryImage(
                create = {
                    resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("无法创建图片")
                },
                write = { uri ->
                    resolver.openOutputStream(uri)?.use { it.write(image.bytes); it.flush() }
                        ?: throw IllegalStateException("无法保存图片")
                },
                publish = { uri ->
                    val complete = ContentValues().apply {
                        put(MediaStore.Images.Media.SIZE, image.bytes.size)
                        if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Images.Media.IS_PENDING, 0)
                    }
                    check(resolver.update(uri, complete, null, null) == 1) { "图片尚未保存完成" }
                },
                rollback = { uri -> resolver.delete(uri, null, null) },
            )
        } catch (error: Exception) {
            legacyFile?.delete()
            throw error
        }
    }
}
