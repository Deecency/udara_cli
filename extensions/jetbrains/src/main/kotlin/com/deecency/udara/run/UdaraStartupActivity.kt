package com.deecency.udara.run

import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity

/** Restores a pubspec version left overridden by a build the IDE didn't see finish. */
class UdaraStartupActivity : ProjectActivity {
    override suspend fun execute(project: Project) {
        VersionOverride.restore(project)
    }
}
