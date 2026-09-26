package com.deecency.udara.ui

import com.deecency.udara.cli.ClientInfo
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.ui.CheckBoxList
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import com.intellij.util.ui.JBUI
import java.awt.FlowLayout
import javax.swing.JButton
import javax.swing.JComponent
import javax.swing.JPanel

/** Picks several clients, platforms and Android types for one batch build. */
class BatchBuildDialog(
    project: Project,
    private val clients: List<ClientInfo>,
    preselected: String?,
    currentVersion: String?,
) : DialogWrapper(project) {
    private val clientList = CheckBoxList<String>()
    private val androidBox = JBCheckBox("Android", true)
    private val iosBox = JBCheckBox("iOS")
    private val aabBox = JBCheckBox("AAB (app bundle)", true)
    private val apkBox = JBCheckBox("APK")
    private val versionField = VersionField(currentVersion)
    private val testBox = JBCheckBox("Use test environment (.env_test)")
    private val failFastBox = JBCheckBox("Stop at the first failed build")
    private val slackBox = JBCheckBox("Send Slack notifications")
    private val channelField = JBTextField("#builds")

    init {
        title = "Build Multiple Clients"
        setOKButtonText("Build")
        for (client in clients) {
            val label = client.name + if (client.summary.isNotEmpty()) "   ${client.summary}" else ""
            clientList.addItem(client.name, label, client.name == preselected)
        }
        androidBox.addChangeListener {
            aabBox.isEnabled = androidBox.isSelected
            apkBox.isEnabled = androidBox.isSelected
        }
        slackBox.addChangeListener { channelField.isEnabled = slackBox.isSelected }
        channelField.isEnabled = false
        init()
    }

    override fun createCenterPanel(): JComponent {
        val selectAll = JButton("Select All").apply { addActionListener { setAll(true) } }
        val selectNone = JButton("Select None").apply { addActionListener { setAll(false) } }
        val clientButtons = JPanel(FlowLayout(FlowLayout.LEFT, 0, 0)).apply {
            add(selectAll)
            add(selectNone)
        }
        val scroll = JBScrollPane(clientList).apply { preferredSize = JBUI.size(380, 180) }
        val platforms = JPanel(FlowLayout(FlowLayout.LEFT, 0, 0)).apply {
            add(androidBox)
            add(iosBox)
        }
        val types = JPanel(FlowLayout(FlowLayout.LEFT, 0, 0)).apply {
            add(aabBox)
            add(apkBox)
        }
        return FormBuilder.createFormBuilder()
            .addLabeledComponent("Clients:", scroll, true)
            .addComponent(clientButtons)
            .addLabeledComponent("Platforms:", platforms)
            .addLabeledComponent("Android types:", types)
            .addLabeledComponent("App version (optional):", versionField.component)
            .addComponent(testBox)
            .addComponent(failFastBox)
            .addComponent(slackBox)
            .addLabeledComponent("Slack channel:", channelField)
            .panel
    }

    private fun setAll(selected: Boolean) {
        for (client in clients) clientList.setItemSelected(client.name, selected)
        clientList.repaint()
    }

    val selectedClients: List<String> get() = clients.map { it.name }.filter { clientList.isItemSelected(it) }

    private val platforms: List<String>
        get() = listOfNotNull("android".takeIf { androidBox.isSelected }, "ios".takeIf { iosBox.isSelected })

    private val androidTypes: List<String>
        get() = listOfNotNull("aab".takeIf { aabBox.isSelected }, "apk".takeIf { apkBox.isSelected })

    /** Number of artifacts the batch will try to produce. */
    val buildCount: Int
        get() = selectedClients.size *
            ((if (androidBox.isSelected) androidTypes.size else 0) + (if (iosBox.isSelected) 1 else 0))

    val overrideVersion: String? get() = versionField.overrideVersion

    override fun doValidate(): ValidationInfo? {
        if (selectedClients.isEmpty()) return ValidationInfo("Select at least one client", clientList)
        if (platforms.isEmpty()) return ValidationInfo("Select Android, iOS or both", androidBox)
        if (androidBox.isSelected && androidTypes.isEmpty()) return ValidationInfo("Select AAB, APK or both", aabBox)
        return versionField.validate()
    }

    fun cliArgs(): List<String> {
        val args = mutableListOf(
            "build",
            "--client", selectedClients.joinToString(","),
            "--platform", platforms.joinToString(","),
        )
        if (androidBox.isSelected) args += listOf("--type", androidTypes.joinToString(","))
        if (testBox.isSelected) args += "--test"
        if (failFastBox.isSelected) args += "--fail-fast"
        if (slackBox.isSelected) {
            args += "--slack"
            channelField.text.trim().takeIf { it.isNotEmpty() }?.let { args += listOf("--slack-channel", it) }
        }
        return args
    }
}
