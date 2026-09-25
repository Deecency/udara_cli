package com.deecency.udara.settings

import com.intellij.openapi.options.Configurable
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent
import javax.swing.JPanel

class UdaraSettingsConfigurable : Configurable {
    private val cliField = JBTextField()
    private val flutterField = JBTextField()
    private val runArgsField = JBTextField()
    private val maskBox = JBCheckBox("Mask secret-looking env values (TOKEN, SECRET, PASSWORD, KEY)")
    private val deviceBox = JBCheckBox("Ask which device to use before flutter run")
    private var panel: JPanel? = null

    override fun getDisplayName(): String = "Udara Whitelabel"

    override fun createComponent(): JComponent {
        val built = FormBuilder.createFormBuilder()
            .addLabeledComponent("udara_cli path or command:", cliField, 1, false)
            .addLabeledComponent("flutter path or command:", flutterField, 1, false)
            .addLabeledComponent("Extra 'flutter run' arguments:", runArgsField, 1, false)
            .addComponent(maskBox, 1)
            .addComponent(deviceBox, 1)
            .addComponentFillVertically(JPanel(), 0)
            .panel
        panel = built
        reset()
        return built
    }

    override fun isModified(): Boolean {
        val s = UdaraSettings.getInstance().state
        return cliField.text != s.cliPath ||
            flutterField.text != s.flutterPath ||
            runArgsField.text != s.flutterRunArgs ||
            maskBox.isSelected != s.maskSecrets ||
            deviceBox.isSelected != s.askForDevice
    }

    override fun apply() {
        val s = UdaraSettings.getInstance().state
        s.cliPath = cliField.text.trim().ifEmpty { "udara_cli" }
        s.flutterPath = flutterField.text.trim().ifEmpty { "flutter" }
        s.flutterRunArgs = runArgsField.text.trim()
        s.maskSecrets = maskBox.isSelected
        s.askForDevice = deviceBox.isSelected
    }

    override fun reset() {
        val s = UdaraSettings.getInstance().state
        cliField.text = s.cliPath
        flutterField.text = s.flutterPath
        runArgsField.text = s.flutterRunArgs
        maskBox.isSelected = s.maskSecrets
        deviceBox.isSelected = s.askForDevice
    }

    override fun disposeUIResources() {
        panel = null
    }
}
