package app.shuyu.reader

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files

class LocalToolsStorageConfinementTest {
    @Test
    fun isPathInsideAllowedRootsAcceptsSubpathsAndRejectsEscapes() {
        val tempRoot = Files.createTempDirectory("shuyu_storage_confinement").toFile()
        try {
            val filesDir = File(tempRoot, "app_files").apply { mkdirs() }
            val cacheDir = File(tempRoot, "app_cache").apply { mkdirs() }
            val allowed = listOf(filesDir, cacheDir)

            assertTrue(isPathInsideAllowedRoots(File(filesDir, "local_books/book.epub"), allowed))
            assertTrue(isPathInsideAllowedRoots(File(cacheDir, "decoded.txt"), allowed))

            // Exact root directory itself is not an interior file path.
            assertFalse(isPathInsideAllowedRoots(filesDir, allowed))

            // Parent directory traversal escaping allowed root must be rejected.
            val escaped = File(filesDir, "../outside_secret.txt")
            assertFalse(isPathInsideAllowedRoots(escaped, allowed))

            // Sibling directory sharing string prefix must be rejected.
            val siblingCollision = File(tempRoot, "app_files_evil/book.epub").apply {
                parentFile?.mkdirs()
                writeText("not allowed")
            }
            assertFalse(isPathInsideAllowedRoots(siblingCollision, allowed))

            // Symlink inside allowed root pointing outside allowed roots must be rejected.
            val outsideTarget = File(tempRoot, "outside.txt").apply { writeText("secret") }
            val symlinkInside = File(filesDir, "linked.txt")
            val createdLink = runCatching {
                Files.createSymbolicLink(symlinkInside.toPath(), outsideTarget.toPath())
                true
            }.getOrDefault(false)
            if (createdLink) {
                assertFalse(isPathInsideAllowedRoots(symlinkInside, allowed))
            }
        } finally {
            tempRoot.deleteRecursively()
        }
    }

    @Test
    fun copyStreamToFileAtomicallyReplacesOnSuccessAndPreservesExistingOnFailure() {
        val tempRoot = Files.createTempDirectory("shuyu_atomic_copy").toFile()
        try {
            val dest = File(tempRoot, "books/novel.epub")
            val initialBytes = "initial-valid-archive".toByteArray(Charsets.UTF_8)
            copyStreamToFileAtomically(
                ByteArrayInputStream(initialBytes),
                dest,
                maxBytes = 1024L,
            )
            assertTrue(dest.isFile)
            assertArrayEquals(initialBytes, dest.readBytes())
            assertEquals(listOf("novel.epub"), dest.parentFile!!.list()!!.toList())

            // Exceeding maxBytes must fail without corrupting or deleting existing dest.
            val oversized = ByteArray(128) { 0x41 }
            assertThrows(IOException::class.java) {
                copyStreamToFileAtomically(
                    ByteArrayInputStream(oversized),
                    dest,
                    maxBytes = 64L,
                )
            }
            assertTrue(dest.isFile)
            assertArrayEquals(initialBytes, dest.readBytes())
            assertEquals(listOf("novel.epub"), dest.parentFile!!.list()!!.toList())

            // Mid-stream IOException must also leave existing dest intact and clean up .part files.
            val failingStream = object : InputStream() {
                private var count = 0
                override fun read(): Int {
                    if (count++ >= 16) throw IOException("simulated provider disconnect")
                    return 0x42
                }
            }
            assertThrows(IOException::class.java) {
                copyStreamToFileAtomically(
                    failingStream,
                    dest,
                    maxBytes = 1024L,
                )
            }
            assertTrue(dest.isFile)
            assertArrayEquals(initialBytes, dest.readBytes())
            assertEquals(listOf("novel.epub"), dest.parentFile!!.list()!!.toList())

            // Subsequent valid replacement succeeds atomically.
            val updatedBytes = "updated-valid-archive-v2".toByteArray(Charsets.UTF_8)
            copyStreamToFileAtomically(
                ByteArrayInputStream(updatedBytes),
                dest,
                maxBytes = 1024L,
            )
            assertArrayEquals(updatedBytes, dest.readBytes())
            assertEquals(listOf("novel.epub"), dest.parentFile!!.list()!!.toList())
        } finally {
            tempRoot.deleteRecursively()
        }
    }
}
