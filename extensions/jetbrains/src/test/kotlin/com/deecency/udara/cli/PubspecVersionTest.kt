package com.deecency.udara.cli

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** Same cases as extensions/vscode/test/pubspecVersion.test.js. */
class PubspecVersionTest {
    @Test
    fun acceptsFlutterVersionFormats() {
        for (ok in listOf("1.0.0", "1.4.0+12", "2.0.0-beta.1", "2.0.0-beta.1+3")) assertTrue(ok, PubspecVersion.PATTERN.matches(ok))
        for (bad in listOf("1.0", "v1.0.0", "1.0.0+", "1.0.0+abc", "latest")) assertFalse(bad, PubspecVersion.PATTERN.matches(bad))
    }

    @Test
    fun resolveKeepsCurrentBuildNumber() {
        assertEquals("1.4.0+41", PubspecVersion.resolve("1.4.0", "1.3.9+41"))
        assertEquals("1.4.0+50", PubspecVersion.resolve("1.4.0+50", "1.3.9+41"))
        assertEquals("1.4.0", PubspecVersion.resolve("1.4.0", "1.3.9"))
        assertNull(PubspecVersion.resolve("  ", "1.3.9+41"))
    }

    @Test
    fun replaceOnlyTouchesTheVersionValue() {
        val src = "name: app\nversion: \"1.0.0+1\" # release\nenvironment:\n  sdk: \">=3.0.0\"\n"
        assertEquals(
            "name: app\nversion: \"2.1.0+7\" # release\nenvironment:\n  sdk: \">=3.0.0\"\n",
            PubspecVersion.replaceIn(src, "2.1.0+7"),
        )
        assertEquals("version: 1.0.1+2\n", PubspecVersion.replaceIn("version: 1.0.0+1\n", "1.0.1+2"))
    }

    @Test(expected = IllegalStateException::class)
    fun ignoresNestedVersionKeys() {
        PubspecVersion.replaceIn("name: app\ndependencies:\n  foo:\n    version: 1.2.3\n", "9.9.9")
    }

    @Test
    fun roundTripsOnDisk() {
        val dir = Files.createTempDirectory("udara-ver").toFile()
        dir.resolve("pubspec.yaml").writeText("name: app\nversion: 1.0.0+1\n")
        assertEquals("1.0.0+1", PubspecVersion.read(dir))
        PubspecVersion.write(dir, "3.2.1+9")
        assertEquals("3.2.1+9", PubspecVersion.read(dir))
        dir.deleteRecursively()
    }
}
