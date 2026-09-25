package com.deecency.udara.ui

import com.intellij.ide.util.PropertiesComponent
import com.intellij.openapi.project.Project

/** Remembers which client the project was last whitelabeled as. */
object ActiveClient {
    private const val KEY = "com.deecency.udara.activeClient"

    fun get(project: Project): String? = PropertiesComponent.getInstance(project).getValue(KEY)

    fun set(project: Project, client: String?) {
        PropertiesComponent.getInstance(project).setValue(KEY, client)
    }
}
