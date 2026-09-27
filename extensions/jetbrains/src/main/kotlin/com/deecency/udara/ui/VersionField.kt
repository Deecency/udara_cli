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

    /** The version for --build-version, or null to keep the pubspec version. */
    val requested: String?
        get() = component.text.trim().takeIf { it.isNotEmpty() }

    fun validate(): ValidationInfo? {
        val input = requested ?: return null
        if (!PubspecVersion.PATTERN.matches(input)) {
            return ValidationInfo("Use x.y.z or x.y.z+build, e.g. 1.4.0 or 1.4.0+12", component)
        }
        return null
    }
}
