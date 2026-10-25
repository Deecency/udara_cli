package com.deecency.udara.cli

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import java.io.File
import java.nio.charset.StandardCharsets

/**
 * The branches `build --ref` can build instead of the working copy. Mirrors
 * extensions/vscode/src/gitBranches.ts; keep the two in sync.
 */
object GitBranches {
    data class Choice(val ref: String, val remote: Boolean)

    /** What the build dialogs offer, with each branch's pubspec version. */
    data class Listing(
        val current: String?,
        val choices: List<Choice>,
        /** pubspec `version:` per [Choice.ref], where it has one. */
        val versions: Map<String, String>,
    )

    /**
     * Local branches except the current one, then remote branches without a
     * local branch of the same name, in the order given (most recently
     * committed first). The CLI builds a local branch as it is on the remote
     * when it hasn't been pulled, so `origin/stable` next to `stable` would
     * only be a duplicate.
     */
    fun choices(current: String?, local: List<String>, remote: List<String>): List<Choice> {
        val localNames = local.toSet()
        val result = local.filter { it != current }.map { Choice(it, remote = false) }.toMutableList()
        for (ref in remote) {
            val name = ref.substringAfter('/')
            if (ref.endsWith("/HEAD") || !ref.contains('/') || name in localNames || name == current) continue
            result += Choice(ref, remote = true)
        }
        return result
    }

    /** Loads the listing; empty outside git. Call off the UI thread. */
    fun load(root: File): Listing {
        val current = git(root, "rev-parse", "--abbrev-ref", "HEAD")?.trim()?.takeIf { it.isNotEmpty() && it != "HEAD" }
        fun refs(namespace: String) =
            git(root, "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", namespace)
                ?.lines()?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()
        val choices = choices(current, refs("refs/heads"), refs("refs/remotes"))
        // Shown as the version hint when a branch is picked; the most recent
        // branches are the ones released from.
        val versions = choices.take(30).mapNotNull { c -> pubspecVersionAt(root, c.ref)?.let { c.ref to it } }.toMap()
        return Listing(current, choices, versions)
    }

    private val VERSION = Regex("""^version:[ \t]*["']?([^"'\s#]+)""", RegexOption.MULTILINE)

    private fun pubspecVersionAt(root: File, ref: String): String? =
        git(root, "show", "$ref:./pubspec.yaml")?.let { VERSION.find(it)?.groupValues?.get(1) }

    private fun git(root: File, vararg args: String): String? = try {
        val output = CapturingProcessHandler(
            GeneralCommandLine(listOf("git") + args).withWorkDirectory(root).withCharset(StandardCharsets.UTF_8),
        ).runProcess(15_000)
        if (output.exitCode == 0 && !output.isTimeout) output.stdout else null
    } catch (_: Exception) {
        null
    }
}
