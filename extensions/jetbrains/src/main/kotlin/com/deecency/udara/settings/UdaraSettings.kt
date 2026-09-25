package com.deecency.udara.settings

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage

@Service(Service.Level.APP)
@State(name = "com.deecency.udara.UdaraSettings", storages = [Storage("udara-whitelabel.xml")])
class UdaraSettings : PersistentStateComponent<UdaraSettings.State> {

    class State {
        var cliPath: String = "udara_cli"
        var flutterPath: String = "flutter"
        var flutterRunArgs: String = ""
        var maskSecrets: Boolean = true
        var askForDevice: Boolean = true
    }

    private var myState = State()

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    companion object {
        fun getInstance(): UdaraSettings =
            ApplicationManager.getApplication().getService(UdaraSettings::class.java)
    }
}
