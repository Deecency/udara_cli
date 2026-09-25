package com.deecency.udara.cli

/** One client as reported by `udara_cli list-clients --json`. */
data class ClientInfo(
    val name: String,
    val path: String,
    val isDefault: Boolean,
    val appName: String?,
    val bundleId: String?,
    val hasFonts: Boolean,
    val envFile: String?,
    val envTestFile: String?,
    val env: Map<String, String>,
    val envTest: Map<String, String>,
) {
    val summary: String
        get() = listOfNotNull(appName, bundleId).joinToString(" · ")
}

data class HistoryEntry(
    val timestamp: String,
    val client: String,
    val platform: String,
    val type: String,
    val version: String?,
    val success: Boolean,
    val durationSeconds: Int,
    val error: String?,
    val artifact: String?,
)

data class FlutterDevice(
    val id: String,
    val name: String,
    val targetPlatform: String?,
    val emulator: Boolean,
)

/** Mirrors the CLI's dotenv rules: quotes, `export`, inline `#` comments. */
object EnvParser {
    private val KEY = Regex("^[A-Za-z_][A-Za-z0-9_]*$")
    private val SECRET = Regex("(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|API_KEY|_KEY$|^KEY$)", RegexOption.IGNORE_CASE)

    fun isSecret(key: String): Boolean = SECRET.containsMatchIn(key)

    fun parse(content: String): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        for (rawLine in content.lines()) {
            var line = rawLine.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            if (line.startsWith("export ")) line = line.removePrefix("export ").trim()
            val eq = line.indexOf('=')
            if (eq <= 0) continue
            val key = line.substring(0, eq).trim()
            if (!KEY.matches(key)) continue
            result[key] = parseValue(line.substring(eq + 1).trim())
        }
        return result
    }

    private fun parseValue(raw: String): String {
        if (raw.isEmpty()) return ""
        val quote = raw[0]
        if (quote == '"' || quote == '\'') {
            val closing = raw.indexOf(quote, 1)
            return if (closing > 0) raw.substring(1, closing) else raw.substring(1)
        }
        val hash = raw.indexOf(" #")
        return (if (hash >= 0) raw.substring(0, hash) else raw).trim()
    }
}
