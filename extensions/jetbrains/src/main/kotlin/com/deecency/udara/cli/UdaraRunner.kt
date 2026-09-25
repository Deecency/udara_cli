package com.deecency.udara.cli

import com.deecency.udara.settings.UdaraSettings
import com.deecency.udara.ui.UdaraNotifications
import com.intellij.execution.ExecutionException
import com.intellij.execution.RunContentExecutor
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.configurations.PtyCommandLine
import com.intellij.execution.process.KillableColoredProcessHandler
import com.intellij.execution.process.ProcessTerminatedListener
import com.intellij.openapi.project.Project
import java.io.File

/** Runs `udara_cli` and `flutter run` with their output in the Run tool window. */
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
        run(project, UdaraCli.commandLine(root, cli, args), title, cli, onFinished)
    }

    /**
     * Runs `flutter <args>` interactively. A pseudo-terminal makes Flutter
     * treat the console as a TTY, so typing r, R or q and pressing Enter in
     * the Run tool window triggers hot reload, hot restart or quit.
     */
    fun runFlutterInteractive(project: Project, root: File, title: String, args: List<String>) {
        val flutter = UdaraSettings.getInstance().state.flutterPath
        val commandLine = PtyCommandLine(UdaraCli.commandLine(root, flutter, args))
            .withInitialColumns(160)
            .withConsoleMode(true)
        run(project, commandLine, title, flutter, null)
    }

    private fun run(
        project: Project,
        commandLine: GeneralCommandLine,
        title: String,
        executable: String,
        onFinished: ((Int) -> Unit)?,
    ) {
        val handler = try {
            KillableColoredProcessHandler(commandLine)
        } catch (e: ExecutionException) {
            UdaraNotifications.cliMissing(project, e.message ?: executable)
            return
        }
        ProcessTerminatedListener.attach(handler)
        RunContentExecutor(project, handler)
            .withTitle(title)
            .withActivateToolWindow(true)
            .withStop({ handler.destroyProcess() }, { !handler.isProcessTerminated })
            .withAfterCompletion { onFinished?.invoke(handler.exitCode ?: -1) }
            .run()
    }
}
