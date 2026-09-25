package com.deecency.udara.ui

import com.deecency.udara.cli.PubspecVersion
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.openapi.ui.ComboBox
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent

class BuildDialog(
    project: Project,
    private val clientName: String,
    private val currentVersion: String?,
) : DialogWrapper(project) {
    private val versionField = JBTextField().apply {
        emptyText.text = currentVersion?.let { "Leave empty for $it" } ?: "e.g. 1.4.0 or 1.4.0+12"
        toolTipText = "Builds this version without editing pubspec.yaml yourself. " +
            "Without a +build number, the current one is kept."
    }
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
            .addLabeledComponent("App version (optional):", versionField)
            .addComponent(testBox)
            .addComponent(slackBox)
            .addLabeledComponent("Slack channel:", channelField)
            .panel

    val platform: String get() = platformBox.selectedItem as String

    /** The version to build, or null to keep the pubspec version. */
    val overrideVersion: String?
        get() = PubspecVersion.resolve(versionField.text, currentVersion)?.takeIf { it != currentVersion }

    override fun doValidate(): ValidationInfo? {
        val input = versionField.text.trim()
        if (input.isEmpty()) return null
        if (!PubspecVersion.PATTERN.matches(input)) {
            return ValidationInfo("Use x.y.z or x.y.z+build, e.g. 1.4.0 or 1.4.0+12", versionField)
        }
        if (currentVersion == null) {
            return ValidationInfo("pubspec.yaml has no \"version:\" line to override", versionField)
        }
        return null
    }

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
