package com.deecency.udara.run

import com.deecency.udara.settings.UdaraSettings
import com.intellij.execution.ProgramRunnerUtil
import com.intellij.execution.RunManager
import com.intellij.execution.RunnerAndConfigurationSettings
import com.intellij.execution.configurations.ConfigurationTypeUtil
import com.intellij.execution.executors.DefaultDebugExecutor
import com.intellij.execution.executors.DefaultRunExecutor
import com.intellij.openapi.project.Project
import com.intellij.util.execution.ParametersListUtil
import org.jdom.Element
import java.io.File

/**
 * Creates one Flutter plugin run configuration per client, e.g. "Udara: acme",
 * so launching goes through the Flutter plugin and gets its usual hot reload,
 * hot restart, DevTools and debugger controls. Uses only public platform APIs:
 * the Flutter plugin is looked up by its configuration type id at runtime,
 * and its fields are set through the standard run-configuration XML state.
 */
object FlutterRunConfigs {
    private const val FLUTTER_TYPE_ID = "FlutterRunConfigurationType"

    fun isAvailable(): Boolean = ConfigurationTypeUtil.findConfigurationType(FLUTTER_TYPE_ID) != null

    fun nameFor(client: String, isTest: Boolean) = "Udara: $client${if (isTest) " (test)" else ""}"

    /** Creates or updates the configuration for [client] and selects it. */
    fun ensure(project: Project, root: File, client: String, isTest: Boolean): RunnerAndConfigurationSettings? {
        val type = ConfigurationTypeUtil.findConfigurationType(FLUTTER_TYPE_ID) ?: return null
        val factory = type.configurationFactories.firstOrNull() ?: return null
        val runManager = RunManager.getInstance(project)
        val name = nameFor(client, isTest)

        val settings = runManager.allSettings.firstOrNull { it.type.id == FLUTTER_TYPE_ID && it.name == name }
            ?: runManager.createConfiguration(name, factory).also { runManager.addConfiguration(it) }

        val userArgs = ParametersListUtil.parse(UdaraSettings.getInstance().state.flutterRunArgs)
        val additionalArgs = ParametersListUtil.join(listOf("--dart-define=CLIENT_ENV=.env") + userArgs)
        val state = Element("configuration")
            .addContent(option("filePath", File(root, "lib/main.dart").path))
            .addContent(option("additionalArgs", additionalArgs))
        settings.configuration.readExternal(state)

        val whitelabel = UdaraBeforeRunTask().also {
            it.client = client
            it.test = isTest
            it.isEnabled = true
        }
        settings.configuration.beforeRunTasks =
            listOf(whitelabel) + settings.configuration.beforeRunTasks.filterNot { it is UdaraBeforeRunTask }

        runManager.selectedConfiguration = settings
        return settings
    }

    fun launch(settings: RunnerAndConfigurationSettings, debug: Boolean) {
        val executor = if (debug) DefaultDebugExecutor.getDebugExecutorInstance() else DefaultRunExecutor.getRunExecutorInstance()
        ProgramRunnerUtil.executeConfiguration(settings, executor)
    }

    private fun option(name: String, value: String) =
        Element("option").setAttribute("name", name).setAttribute("value", value)
}
