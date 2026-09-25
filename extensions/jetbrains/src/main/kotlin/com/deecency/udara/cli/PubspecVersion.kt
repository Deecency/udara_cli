package com.deecency.udara.cli

import java.io.File

/**
 * Reads and rewrites the top-level `version:` line of pubspec.yaml. Mirrors
 * extensions/vscode/src/pubspecVersion.ts; keep the two in sync.
 */
object PubspecVersion {
    /** Flutter's format: build-name with an optional +build-number. */
    val PATTERN = Regex("""^\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?(?:\+\d+)?$""")

    private val LINE = Regex("""^(version:[ \t]*)(["']?)([^"'\s#]+)\2(.*)$""", RegexOption.MULTILINE)

    fun file(root: File) = File(root, "pubspec.yaml")

    fun read(root: File): String? {
        val f = file(root)
        if (!f.isFile) return null
        return LINE.find(f.readText())?.groupValues?.get(3)
    }

    /**
     * "1.4.0" on a pubspec at "1.3.9+41" becomes "1.4.0+41" so the store
     * build number is kept unless one is given. Blank input means no override.
     */
    fun resolve(input: String, current: String?): String? {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.contains('+') || current == null || !current.contains('+')) return trimmed
        return "$trimmed+${current.substringAfter('+')}"
    }

    fun replaceIn(content: String, version: String): String {
        val m = LINE.find(content) ?: error("pubspec.yaml has no \"version:\" line to override.")
        val (prefix, quote, _, rest) = m.destructured
        return content.replaceRange(m.range, "$prefix$quote$version$quote$rest")
    }

    fun write(root: File, version: String) {
        val f = file(root)
        f.writeText(replaceIn(f.readText(), version))
    }
}
