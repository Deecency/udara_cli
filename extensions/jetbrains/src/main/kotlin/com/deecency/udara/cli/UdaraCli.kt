package com.deecency.udara.cli

import com.deecency.udara.settings.UdaraSettings
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.openapi.project.Project
import java.io.File
import java.nio.charset.StandardCharsets

sealed class ClientListing(val clients: List<ClientInfo>) {
    class FromCli(clients: List<ClientInfo>) : ClientListing(clients)
    class Fallback(clients: List<ClientInfo>, val cliError: String) : ClientListing(clients)
}

/** Thin wrapper around the `udara_cli` and `flutter` executables. */
object UdaraCli {
    const val HISTORY_FILE = ".udara_build_history.json"

    /** The Flutter project root: the IDE project, or its first child with a pubspec. */
    fun projectRoot(project: Project): File? {
        val base = project.basePath ?: return null
        val root = File(base)
        if (File(root, "clients").isDirectory || File(root, "pubspec.yaml").isFile) return root
        return root.listFiles()
            ?.filter { it.isDirectory && !it.name.startsWith(".") }
            ?.firstOrNull { File(it, "pubspec.yaml").isFile }
    }

    fun commandLine(root: File, executable: String, args: List<String>): GeneralCommandLine =
        GeneralCommandLine(listOf(executable) + args)
            .withWorkDirectory(root)
            .withCharset(StandardCharsets.UTF_8)
            // CONSOLE loads the user's shell environment, so ~/.pub-cache/bin is on PATH.
            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)

    fun listClients(root: File): ClientListing {
        val cli = UdaraSettings.getInstance().state.cliPath
        return try {
            val output = CapturingProcessHandler(commandLine(root, cli, listOf("list-clients", "--json")))
                .runProcess(30_000)
            if (output.isTimeout) error("udara_cli timed out")
            if (output.exitCode != 0) error(output.stderr.trim().ifBlank { "exit code ${output.exitCode}" })
            ClientListing.FromCli(parseClients(output.stdout))
        } catch (e: Exception) {
            ClientListing.Fallback(scanClients(root), e.message ?: e.toString())
        }
    }

    fun readHistory(root: File): List<HistoryEntry> {
        val file = File(root, HISTORY_FILE)
        if (!file.isFile) return emptyList()
        return try {
            JsonParser.parseString(file.readText()).asJsonArray.map { el ->
                val o = el.asJsonObject
                HistoryEntry(
                    timestamp = o.str("timestamp") ?: "",
                    client = o.str("client") ?: "?",
                    platform = o.str("platform") ?: "?",
                    type = o.str("type") ?: "?",
                    version = o.str("version"),
                    success = o.get("success")?.asBoolean ?: false,
                    durationSeconds = o.get("durationSeconds")?.asInt ?: 0,
                    error = o.str("error"),
                    artifact = o.str("artifact"),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun listDevices(root: File): List<FlutterDevice> {
        val flutter = UdaraSettings.getInstance().state.flutterPath
        return try {
            val output = CapturingProcessHandler(commandLine(root, flutter, listOf("devices", "--machine")))
                .runProcess(60_000)
            val text = output.stdout
            val start = text.indexOf('[')
            val end = text.lastIndexOf(']')
            if (output.exitCode != 0 || start < 0 || end < start) return emptyList()
            JsonParser.parseString(text.substring(start, end + 1)).asJsonArray.map { el ->
                val o = el.asJsonObject
                FlutterDevice(
                    id = o.str("id") ?: "",
                    name = o.str("name") ?: o.str("id") ?: "?",
                    targetPlatform = o.str("targetPlatform"),
                    emulator = o.get("emulator")?.asBoolean ?: false,
                )
            }.filter { it.id.isNotEmpty() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    // -----------------------------------------------------------------------

    private fun parseClients(json: String): List<ClientInfo> {
        val obj = JsonParser.parseString(json).asJsonObject
        return obj.getAsJsonArray("clients").map { el ->
            val c = el.asJsonObject
            val envFiles = c.getAsJsonObject("envFiles")
            ClientInfo(
                name = c.str("name") ?: "?",
                path = c.str("path") ?: "",
                isDefault = c.get("isDefault")?.asBoolean ?: false,
                appName = c.str("appName"),
                bundleId = c.str("bundleId"),
                hasFonts = c.get("hasFonts")?.asBoolean ?: false,
                envFile = envFiles?.str("env"),
                envTestFile = envFiles?.str("envTest"),
                env = c.getAsJsonObject("env").toStringMap(),
                envTest = c.getAsJsonObject("envTest").toStringMap(),
            )
        }
    }

    /** Browsing works without the CLI; run/build actions need it. */
    private fun scanClients(root: File): List<ClientInfo> {
        val clientsDir = File(root, "clients")
        val dirs = clientsDir.listFiles()?.filter { it.isDirectory }?.sortedBy { it.name } ?: return emptyList()
        return dirs.map { dir ->
            val envFile = File(dir, ".env").takeIf { it.isFile }
            val envTestFile = File(dir, ".env_test").takeIf { it.isFile }
            val env = envFile?.let { EnvParser.parse(it.readText()) } ?: emptyMap()
            val fonts = File(dir, "fonts")
            ClientInfo(
                name = dir.name,
                path = dir.absolutePath,
                isDefault = dir.name == "default",
                appName = env["APP_NAME_PROD"],
                bundleId = env["BUNDLE_ID"],
                hasFonts = fonts.isDirectory && (fonts.listFiles()?.any { it.isFile && !it.name.startsWith(".") } ?: false),
                envFile = envFile?.absolutePath,
                envTestFile = envTestFile?.absolutePath,
                env = env,
                envTest = envTestFile?.let { EnvParser.parse(it.readText()) } ?: emptyMap(),
            )
        }
    }

    private fun JsonObject.str(key: String): String? =
        get(key)?.takeUnless { it.isJsonNull }?.asString

    private fun JsonObject?.toStringMap(): Map<String, String> =
        this?.entrySet()?.associate { (k, v) -> k to (v.takeUnless { it.isJsonNull }?.asString ?: "") }
            ?: emptyMap()
}
