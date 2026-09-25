package com.deecency.udara.ui

import com.intellij.ide.actions.RevealFileAction
import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.options.ShowSettingsUtil
import com.intellij.openapi.project.Project
import java.io.File

object UdaraNotifications {
    private fun group() = NotificationGroupManager.getInstance().getNotificationGroup("Udara")

    fun info(project: Project, title: String, content: String = "") =
        group().createNotification(title, content, NotificationType.INFORMATION).notify(project)

    fun warn(project: Project, title: String, content: String = "") =
        group().createNotification(title, content, NotificationType.WARNING).notify(project)

    fun error(project: Project, title: String, content: String = "") =
        group().createNotification(title, content, NotificationType.ERROR).notify(project)

    fun cliMissing(project: Project, detail: String) {
        val tooOld = detail.contains("--json")
        group().createNotification(
            if (tooOld) "udara_cli is too old for this plugin" else "udara_cli could not be run",
            if (tooOld) "This plugin needs udara_cli 1.2.0 or newer. Upgrade with `dart pub global activate udara_cli`."
            else "$detail\nInstall it with `dart pub global activate udara_cli` or set its path in Settings.",
            NotificationType.WARNING,
        ).addAction(NotificationAction.createSimple("Open Settings") {
            ShowSettingsUtil.getInstance().showSettingsDialog(project, "Udara Whitelabel")
        }).notify(project)
    }

    fun whitelabelFailed(project: Project, root: File, client: String, exitCode: Int, outputTail: String) {
        group().createNotification(
            "Whitelabel for \"$client\" failed (exit code $exitCode)",
            outputTail.ifBlank { "Run Doctor to check the client setup." },
            NotificationType.ERROR,
        ).addAction(NotificationAction.createSimple("Run Doctor") {
            com.deecency.udara.cli.UdaraRunner.runCli(project, root, "udara doctor $client", listOf("doctor", "--client", client))
        }).notify(project)
    }

    fun buildFinished(project: Project, client: String, exitCode: Int, artifact: String?, onDoctor: () -> Unit) {
        if (exitCode == 0) {
            val n = group().createNotification(
                "Build for \"$client\" succeeded",
                artifact?.let { File(it).name } ?: "",
                NotificationType.INFORMATION,
            )
            if (artifact != null) {
                n.addAction(NotificationAction.createSimple("Reveal Artifact") {
                    RevealFileAction.openFile(File(artifact))
                })
            }
            n.notify(project)
        } else {
            group().createNotification(
                "Build for \"$client\" failed",
                "Exit code $exitCode. See the Run tool window.",
                NotificationType.ERROR,
            ).addAction(NotificationAction.createSimple("Run Doctor") { onDoctor() }).notify(project)
        }
    }
}
