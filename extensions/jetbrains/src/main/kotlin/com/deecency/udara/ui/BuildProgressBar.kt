package com.deecency.udara.ui

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.intellij.ui.components.JBLabel
import com.intellij.util.ui.JBUI
import java.awt.BorderLayout
import java.io.File
import javax.swing.JPanel
import javax.swing.JProgressBar
import javax.swing.Timer

/**
 * Shows a running build's percent, ETA and per-job steps, read once a second
 * from the file written by `udara_cli build --progress-file`.
 */
class BuildProgressBar : JPanel(BorderLayout(0, JBUI.scale(2))) {
    private val bar = JProgressBar(0, 1000).apply { isStringPainted = true }
    private val title = JBLabel()
    private val detail = JBLabel().apply { foreground = JBUI.CurrentTheme.ContextHelp.FOREGROUND }
    private var file: File? = null
    private val poll = Timer(1000) { update() }
    private val hide = Timer(8000) { isVisible = false }.apply { isRepeats = false }

    init {
        border = JBUI.Borders.empty(4, 8, 6, 8)
        add(title, BorderLayout.NORTH)
        add(bar, BorderLayout.CENTER)
        add(detail, BorderLayout.SOUTH)
        isVisible = false
    }

    fun start(progressFile: File, label: String) {
        hide.stop()
        file = progressFile
        title.text = label
        detail.text = "Starting…"
        bar.value = 0
        bar.string = "0%"
        isVisible = true
        poll.start()
    }

    /** Stops polling and shows the final state for a few seconds. */
    fun stop(summary: String) {
        update()
        poll.stop()
        file = null
        detail.text = summary
        hide.restart()
    }

    fun dispose() {
        poll.stop()
        hide.stop()
    }

    private fun update() {
        val snapshot = file?.takeIf { it.isFile }?.let {
            runCatching { JsonParser.parseString(it.readText()).asJsonObject }.getOrNull()
        } ?: return

        val finished = snapshot.get("finished")?.asBoolean == true
        val percent = snapshot.get("percent")?.asDouble ?: 0.0
        val shown = if (finished) 100.0 else minOf(percent, 99.0)
        bar.value = (shown * 10).toInt()
        bar.string = "${shown.toInt()}%" + if (finished) "" else " · ETA ~${formatSeconds(snapshot.int("etaSeconds"))}"

        val jobs = snapshot.getAsJsonArray("jobs")?.map { it.asJsonObject } ?: emptyList()
        val done = snapshot.int("jobsDone")
        val failed = snapshot.int("jobsFailed")
        val running = jobs.filter { it.str("state") == "running" }
            .joinToString(" · ") { "${it.str("client")} ${it.str("platform")}: ${it.str("step") ?: "starting"}" }
        detail.text = buildString {
            if (jobs.size > 1) append("$done/${jobs.size} jobs done${if (failed > 0) ", $failed failed" else ""}")
            if (running.isNotEmpty()) {
                if (isNotEmpty()) append(" · ")
                append(running)
            }
        }
    }

    private fun JsonObject.int(key: String) = get(key)?.takeUnless { it.isJsonNull }?.asInt ?: 0
    private fun JsonObject.str(key: String) = get(key)?.takeUnless { it.isJsonNull }?.asString

    companion object {
        fun formatSeconds(total: Int): String = when {
            total >= 3600 -> "${total / 3600}h ${"%02d".format((total % 3600) / 60)}m"
            total >= 60 -> "${total / 60}m ${"%02d".format(total % 60)}s"
            else -> "${total}s"
        }
    }
}
