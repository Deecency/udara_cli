package com.deecency.udara.ui

import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.ComboBox
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent

class BuildDialog(project: Project, private val clientName: String) : DialogWrapper(project) {
    private val platformBox = ComboBox(arrayOf("android", "ios"))
    private val typeBox = ComboBox(arrayOf("aab", "apk"))
    private val testBox = JBCheckBox("Use test environment (.env_test)")
    private val slackBox = JBCheckBox("Send Slack notifications")
    private val channelField = JBTextField("#builds")

    init {
        title = "Build \"$clientName\""
        setOKButtonText("Build")
        platformBox.addActionListener { typeBox.isEnabled = platformBox.selectedItem == "android" }
        slackBox.addChangeListener { channelField.isEnabled = slackBox.isSelected }
        channelField.isEnabled = false
        init()
    }

    override fun createCenterPanel(): JComponent =
        FormBuilder.createFormBuilder()
            .addLabeledComponent("Platform:", platformBox)
            .addLabeledComponent("Android build type:", typeBox)
            .addComponent(testBox)
            .addComponent(slackBox)
            .addLabeledComponent("Slack channel:", channelField)
            .panel

    val platform: String get() = platformBox.selectedItem as String

    fun cliArgs(): List<String> {
        val args = mutableListOf("build", "--client", clientName, "--platform", platform)
        if (platform == "android") args += listOf("--type", typeBox.selectedItem as String)
        if (testBox.isSelected) args += "--test"
        if (slackBox.isSelected) {
            args += "--slack"
            channelField.text.trim().takeIf { it.isNotEmpty() }?.let { args += listOf("--slack-channel", it) }
        }
        return args
    }
}
