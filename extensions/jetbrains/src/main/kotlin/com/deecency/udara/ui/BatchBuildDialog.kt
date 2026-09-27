package com.deecency.udara.ui

import com.deecency.udara.cli.ClientInfo
import com.deecency.udara.cli.PubspecVersion
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.ComboBox
import com.intellij.openapi.ui.DialogWrapper
import com.intellij.openapi.ui.ValidationInfo
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextField
import com.intellij.ui.table.JBTable
import com.intellij.util.ui.FormBuilder
import com.intellij.util.ui.JBUI
import java.awt.FlowLayout
import javax.swing.JButton
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.table.AbstractTableModel

/**
 * Picks clients (each with an optional version of its own), platforms,
 * Android types and how many builds run at the same time.
 */
class BatchBuildDialog(
    project: Project,
    clients: List<ClientInfo>,
    preselected: String?,
    private val currentVersion: String?,
) : DialogWrapper(project) {

    private class Row(val client: ClientInfo, var selected: Boolean, var version: String)

    private val rows = clients.map { Row(it, it.name == preselected, "") }

    private val tableModel = object : AbstractTableModel() {
        private val columns = arrayOf("", "Client", "App · bundle id", "Version (optional)")
        override fun getRowCount() = rows.size
        override fun getColumnCount() = columns.size
        override fun getColumnName(column: Int) = columns[column]
        override fun getColumnClass(column: Int) = if (column == 0) java.lang.Boolean::class.java else String::class.java
        override fun isCellEditable(row: Int, column: Int) = column == 0 || column == 3
        override fun getValueAt(row: Int, column: Int): Any = when (column) {
            0 -> rows[row].selected
            1 -> rows[row].client.name
            2 -> rows[row].client.summary
            else -> rows[row].version
        }

        override fun setValueAt(value: Any?, row: Int, column: Int) {
            when (column) {
                0 -> rows[row].selected = value == true
                3 -> {
                    rows[row].version = value?.toString()?.trim() ?: ""
                    // Typing a version implies building that client.
                    if (rows[row].version.isNotEmpty()) rows[row].selected = true
                }
            }
            fireTableRowsUpdated(row, row)
        }
    }

    private val table = JBTable(tableModel).apply {
        setShowGrid(false)
        columnModel.getColumn(0).apply { maxWidth = JBUI.scale(30) }
        columnModel.getColumn(3).preferredWidth = JBUI.scale(130)
        emptyText.text = "No clients"
    }
    private val sameVersionField = JBTextField().apply {
        emptyText.text = currentVersion?.let { "e.g. 1.4.0+12 (pubspec: $it)" } ?: "e.g. 1.4.0+12"
        columns = 14
    }
    private val androidBox = JBCheckBox("Android", true)
    private val iosBox = JBCheckBox("iOS")
    private val aabBox = JBCheckBox("AAB (app bundle)", true)
    private val apkBox = JBCheckBox("APK")
    private val parallelBox = ComboBox(arrayOf("Auto (recommended)", "1 (one at a time)", "2", "3", "4"))
    private val testBox = JBCheckBox("Use test environment (.env_test)")
    private val failFastBox = JBCheckBox("Stop at the first failed build")
    private val slackBox = JBCheckBox("Send Slack notifications")
    private val channelField = JBTextField("#builds")

    init {
        title = "Build Multiple Clients"
        setOKButtonText("Build")
        androidBox.addChangeListener {
            aabBox.isEnabled = androidBox.isSelected
            apkBox.isEnabled = androidBox.isSelected
        }
        slackBox.addChangeListener { channelField.isEnabled = slackBox.isSelected }
        channelField.isEnabled = false
        init()
    }

    override fun createCenterPanel(): JComponent {
        fun row(vararg components: JComponent) = JPanel(FlowLayout(FlowLayout.LEFT, 0, 0)).apply {
            components.forEach { add(it) }
        }

        val selectAll = JButton("Select All").apply { addActionListener { setAll(true) } }
        val selectNone = JButton("Select None").apply { addActionListener { setAll(false) } }
        val applyVersion = JButton("Apply to Selected").apply {
            addActionListener {
                if (table.isEditing) table.cellEditor.stopCellEditing()
                val v = sameVersionField.text.trim()
                rows.filter { it.selected }.forEach { it.version = v }
                tableModel.fireTableDataChanged()
            }
        }
        val scroll = JBScrollPane(table).apply { preferredSize = JBUI.size(520, 200) }

        return FormBuilder.createFormBuilder()
            .addLabeledComponent("Clients:", scroll, true)
            .addComponent(row(selectAll, selectNone))
            .addLabeledComponent("Same version for selected:", row(sameVersionField, applyVersion))
            .addComponent(
                JBLabel("Empty version keeps the pubspec version${currentVersion?.let { " ($it)" } ?: ""}. " +
                    "Without +build number the pubspec one is kept.").apply {
                    foreground = JBUI.CurrentTheme.ContextHelp.FOREGROUND
                },
            )
            .addLabeledComponent("Platforms:", row(androidBox, iosBox))
            .addLabeledComponent("Android types:", row(aabBox, apkBox))
            .addLabeledComponent("Build at the same time:", parallelBox)
            .addComponent(testBox)
            .addComponent(failFastBox)
            .addComponent(slackBox)
            .addLabeledComponent("Slack channel:", channelField)
            .panel
    }

    private fun setAll(selected: Boolean) {
        rows.forEach { it.selected = selected }
        tableModel.fireTableDataChanged()
    }

    private val selectedRows: List<Row> get() = rows.filter { it.selected }

    private val platforms: List<String>
        get() = listOfNotNull("android".takeIf { androidBox.isSelected }, "ios".takeIf { iosBox.isSelected })

    private val androidTypes: List<String>
        get() = listOfNotNull("aab".takeIf { aabBox.isSelected }, "apk".takeIf { apkBox.isSelected })

    /** Number of artifacts the batch will try to produce. */
    val buildCount: Int
        get() = selectedRows.size *
            ((if (androidBox.isSelected) androidTypes.size else 0) + (if (iosBox.isSelected) 1 else 0))

    override fun doValidate(): ValidationInfo? {
        if (table.isEditing) table.cellEditor.stopCellEditing()
        if (selectedRows.isEmpty()) return ValidationInfo("Select at least one client", table)
        selectedRows.firstOrNull { it.version.isNotEmpty() && !PubspecVersion.PATTERN.matches(it.version) }?.let {
            return ValidationInfo("${it.client.name}: use x.y.z or x.y.z+build, e.g. 1.4.0 or 1.4.0+12", table)
        }
        if (platforms.isEmpty()) return ValidationInfo("Select Android, iOS or both", androidBox)
        if (androidBox.isSelected && androidTypes.isEmpty()) return ValidationInfo("Select AAB, APK or both", aabBox)
        return null
    }

    fun cliArgs(): List<String> {
        val args = mutableListOf(
            "build",
            "--client", selectedRows.joinToString(",") { it.client.name },
            "--platform", platforms.joinToString(","),
        )
        if (androidBox.isSelected) args += listOf("--type", androidTypes.joinToString(","))
        val versions = selectedRows.filter { it.version.isNotEmpty() }.map { "${it.client.name}=${it.version}" }
        if (versions.isNotEmpty()) args += listOf("--build-version", versions.joinToString(","))
        args += listOf("--parallel", if (parallelBox.selectedIndex == 0) "auto" else parallelBox.selectedIndex.toString())
        if (testBox.isSelected) args += "--test"
        if (failFastBox.isSelected) args += "--fail-fast"
        if (slackBox.isSelected) {
            args += "--slack"
            channelField.text.trim().takeIf { it.isNotEmpty() }?.let { args += listOf("--slack-channel", it) }
        }
        return args
    }
}
