package com.deecency.udara.ui

import com.deecency.udara.cli.PubspecVersion
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.ui.components.JBTextField

/** Optional "App version" input shared by the build dialogs. */
class VersionField(private val currentVersion: String?) {
    val component = JBTextField().apply {
        emptyText.text = currentVersion?.let { "Leave empty for $it" } ?: "e.g. 1.4.0 or 1.4.0+12"
        toolTipText = "Builds this version without editing pubspec.yaml yourself. " +
            "Without a +build number, the current one is kept."
    }

    /** The version to build, or null to keep the pubspec version. */
    val overrideVersion: String?
        get() = PubspecVersion.resolve(component.text, currentVersion)?.takeIf { it != currentVersion }

    fun validate(): ValidationInfo? {
        val input = component.text.trim()
        if (input.isEmpty()) return null
        if (!PubspecVersion.PATTERN.matches(input)) {
            return ValidationInfo("Use x.y.z or x.y.z+build, e.g. 1.4.0 or 1.4.0+12", component)
        }
        if (currentVersion == null) {
            return ValidationInfo("pubspec.yaml has no \"version:\" line to override", component)
        }
        return null
    }
}
