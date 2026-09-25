package com.deecency.udara.cli

import com.deecency.udara.settings.UdaraSettings
import com.deecency.udara.ui.UdaraNotifications
import com.intellij.execution.ExecutionException
import com.intellij.execution.RunContentExecutor
import com.intellij.execution.process.KillableColoredProcessHandler
import com.intellij.execution.process.ProcessTerminatedListener
import com.intellij.openapi.project.Project
import org.jetbrains.plugins.terminal.TerminalToolWindowManager
import java.io.File

/** Runs the CLI in the Run tool window and `flutter run` in the Terminal. */
object UdaraRunner {

    /**
     * Runs `udara_cli <args>` with its output in the Run tool window.
     * [onFinished] receives the exit code on the EDT once the process ends.
     */
    fun runCli(
        project: Project,
        root: File,
        title: String,
        args: List<String>,
        onFinished: ((Int) -> Unit)? = null,
    ) {
        val cli = UdaraSettings.getInstance().state.cliPath
        val handler = try {
            KillableColoredProcessHandler(UdaraCli.commandLine(root, cli, args))
        } catch (e: ExecutionException) {
            UdaraNotifications.cliMissing(project, e.message ?: cli)
            return
        }
        ProcessTerminatedListener.attach(handler)
        RunContentExecutor(project, handler)
            .withTitle(title)
            .withActivateToolWindow(true)
            .withAfterCompletion { onFinished?.invoke(handler.exitCode ?: -1) }
            .run()
    }

    /** Opens a new Terminal tab in [root] and executes [command] in it. */
    fun runInTerminal(project: Project, root: File, tabName: String, command: String) {
        val widget = TerminalToolWindowManager.getInstance(project)
            .createShellWidget(root.absolutePath, tabName, true, true)
        widget.sendCommandToExecute(command)
    }

    fun commandLine(executable: String, args: List<String>): String =
        (listOf(executable) + args).joinToString(" ") { quote(it) }

    private val SAFE = Regex("^[A-Za-z0-9_./=:@+-]+$")

    private fun quote(arg: String): String = when {
        SAFE.matches(arg) -> arg
        System.getProperty("os.name").lowercase().contains("win") -> "\"" + arg.replace("\"", "\\\"") + "\""
        else -> "'" + arg.replace("'", "'\\''") + "'"
    }
}
