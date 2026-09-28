package com.deecency.udara.cli

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.file.Files

class AppConfigModeTest {
    private fun modeFor(yaml: String?): String {
        val dir = Files.createTempDirectory("udara-mode").toFile()
        if (yaml != null) dir.resolve("udara.yaml").writeText(yaml)
        return UdaraCli.appConfigMode(dir).also { dir.deleteRecursively() }
    }

    @Test
    fun defaultsToDotenv() {
        assertEquals("dotenv", modeFor(null))
        assertEquals("dotenv", modeFor("hooks:\n  after_build: echo hi\n"))
    }

    @Test
    fun readsGeneratedMode() {
        assertEquals("generated", modeFor("# settings\napp_config:\n  # compiled\n  mode: generated\n  output: lib/x.dart\n"))
        assertEquals("generated", modeFor("hooks:\n  after_build: x\napp_config:\n  mode: \"generated\"\n"))
    }

    @Test
    fun ignoresModeOutsideAppConfig() {
        assertEquals("dotenv", modeFor("app_config:\n  output: lib/x.dart\nother:\n  mode: generated\n"))
    }
}
