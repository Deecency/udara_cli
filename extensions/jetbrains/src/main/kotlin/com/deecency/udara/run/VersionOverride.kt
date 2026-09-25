package com.deecency.udara.run

import com.deecency.udara.cli.PubspecVersion
import com.deecency.udara.ui.UdaraNotifications
import com.intellij.ide.util.PropertiesComponent
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import java.io.File

/**
 * Temporarily sets pubspec.yaml's version for one build. udara_cli takes the
 * version from pubspec (artifact name, history, Slack) and Flutter builds
 * with it, so the CLI needs no extra flag. The original is persisted so it
 * can be put back after a crash or IDE restart.
 */
object VersionOverride {
    private const val KEY = "com.deecency.udara.pendingVersionRestore"
    private const val SEP = "\u0000"

    /** Must be called on the EDT (saves open documents first). */
    fun apply(project: Project, root: File, original: String, override: String) {
        // Don't clobber unsaved edits to pubspec.yaml.
        FileDocumentManager.getInstance().saveAllDocuments()
        PropertiesComponent.getInstance(project).setValue(KEY, listOf(root.path, original, override).joinToString(SEP))
        PubspecVersion.write(root, override)
        refresh(root)
    }

    /** Puts back an overridden version. Safe to call when nothing is pending. */
    fun restore(project: Project) {
        val props = PropertiesComponent.getInstance(project)
        val pending = props.getValue(KEY) ?: return
        val parts = pending.split(SEP)
        props.unsetValue(KEY)
        if (parts.size != 3) return
        val (rootPath, original, override) = parts
        val root = File(rootPath)
        try {
            // Only restore if nobody changed the version since we set it.
            if (PubspecVersion.read(root) == override) {
                PubspecVersion.write(root, original)
                refresh(root)
            }
        } catch (e: Exception) {
            UdaraNotifications.warn(project, "Could not restore pubspec version $original", e.message ?: e.toString())
        }
    }

    private fun refresh(root: File) {
        LocalFileSystem.getInstance().refreshAndFindFileByIoFile(PubspecVersion.file(root))?.refresh(false, false)
    }
}
