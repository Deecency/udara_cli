package com.deecency.udara.ui

import com.deecency.udara.cli.ClientInfo
import com.deecency.udara.cli.UdaraCli
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.popup.JBPopupFactory
import com.intellij.ui.SimpleListCellRenderer

/** Pops up a client list when an action is invoked without a tree selection. */
object ClientChooser {
    fun choose(project: Project, title: String, onChosen: (ClientInfo) -> Unit) {
        val root = UdaraCli.projectRoot(project)
        if (root == null) {
            UdaraNotifications.warn(project, "No Flutter project", "Open a project containing pubspec.yaml.")
            return
        }
        ApplicationManager.getApplication().executeOnPooledThread {
            val listing = UdaraCli.listClients(root)
            ApplicationManager.getApplication().invokeLater {
                if (listing.clients.isEmpty()) {
                    UdaraNotifications.warn(
                        project, "No clients found",
                        "Use Tools | Udara Whitelabel | Set Up Clients… to create some.",
                    )
                    return@invokeLater
                }
                JBPopupFactory.getInstance()
                    .createPopupChooserBuilder(listing.clients)
                    .setTitle(title)
                    .setRenderer(SimpleListCellRenderer.create<ClientInfo> { label, value, _ ->
                        label.text = value.name + if (value.summary.isNotEmpty()) "   ${value.summary}" else ""
                    })
                    .setItemChosenCallback { onChosen(it) }
                    .createPopup()
                    .showCenteredInCurrentWindow(project)
            }
        }
    }
}
