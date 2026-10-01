package dev.fluxdown.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QrValidationTest {
    @Test
    fun torrentSingleFileUsesDirectoryEntryLabel() {
        assertEquals(
            "episode-01",
            torrentResourceDirectoryLabel("episode-01.mkv", listOf("episode-01.mkv")),
        )
    }

    @Test
    fun torrentMultiFileKeepsMetadataDirectoryName() {
        assertEquals(
            "bundle",
            torrentResourceDirectoryLabel("bundle", listOf("a.bin", "b.bin")),
        )
    }

    @Test
    fun acceptsRawValueWhenRustDetectsProtocol() {
        val result = firstValidatedQrDownloadSource(listOf("https://example.test/file.bin" to null)) { "https" }

        assertEquals("https://example.test/file.bin", result)
    }

    @Test
    fun fallsBackToDisplayValue() {
        val result = firstValidatedQrDownloadSource(listOf(null to "magnet:?xt=urn:btih:test")) { "magnet" }

        assertEquals("magnet:?xt=urn:btih:test", result)
    }

    @Test
    fun skipsUnknownCandidateAndAcceptsLaterDownloadCode() {
        val result = firstValidatedQrDownloadSource(
            listOf("普通文本" to null, "http://example.test/a" to null),
        ) { value -> if (value.startsWith("http")) "http" else "unknown" }

        assertEquals("http://example.test/a", result)
    }

    @Test
    fun rejectsEmptyUnknownAndOverlongValues() {
        val result = firstValidatedQrDownloadSource(
            listOf("   " to null, "x".repeat(8193) to null, "ed2k://file" to null),
        ) { "unknown" }

        assertNull(result)
    }
}
