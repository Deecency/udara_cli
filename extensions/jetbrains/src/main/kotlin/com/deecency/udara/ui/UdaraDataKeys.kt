package com.deecency.udara.ui

import com.deecency.udara.cli.ClientInfo
import com.intellij.openapi.actionSystem.DataKey

object UdaraDataKeys {
    /** The client selected in the Udara tool window, when the action came from there. */
    @JvmField
    val CLIENT: DataKey<ClientInfo> = DataKey.create("udara.selectedClient")

    @JvmField
    val PANEL: DataKey<UdaraPanel> = DataKey.create("udara.panel")
}
