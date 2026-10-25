package com.deecency.udara.ui

import com.deecency.udara.cli.GitBranches
import com.intellij.openapi.ui.ComboBox
import javax.swing.JComponent

/**
 * "Build from" input shared by the build dialogs: the working copy, as
 * always, or another branch, which the CLI builds in a separate copy of the
 * project (`--ref`) so the project stays on its branch with its changes.
 */
class BranchField(private val listing: GitBranches.Listing, private val workingCopyVersion: String?) {
    private class Item(val ref: String?, val label: String) {
        override fun toString() = label
    }

    private val items = listOf(
        Item(null, "Working copy${listing.current?.let { " ($it)" } ?: ""}, as it is now"),
    ) + listing.choices.map { Item(it.ref, if (it.remote) "${it.ref} (remote branch)" else it.ref) }

    private val combo = ComboBox(items.toTypedArray()).apply {
        toolTipText = "Another branch is built in a separate copy of the project, as it is on the remote. " +
            "Your project, its branch and uncommitted changes are left as they are."
    }

    val component: JComponent get() = combo

    /** Whether there is anything to choose besides the working copy. */
    val hasChoices: Boolean get() = listing.choices.isNotEmpty()

    /** The branch for --ref, or null for the working copy. */
    val ref: String? get() = (combo.selectedItem as Item).ref

    /** The pubspec version of what is selected, for the version hints. */
    val pubspecVersion: String? get() = ref?.let { listing.versions[it] } ?: workingCopyVersion.takeIf { ref == null }

    fun onChange(listener: () -> Unit) = combo.addActionListener { listener() }
}
