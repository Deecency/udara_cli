plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.1.20"
    id("org.jetbrains.intellij.platform") version "2.5.0"
}

group = "com.deecency.udara"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        // Android Studio Ladybug and newer are built on the 2024.2 platform;
        // building against IntelliJ Community keeps the download small.
        intellijIdeaCommunity("2024.2.5")
        bundledPlugin("org.jetbrains.plugins.terminal")
    }
}

intellijPlatform {
    pluginConfiguration {
        id = "com.deecency.udara"
        name = "Udara Whitelabel"
        version = project.version.toString()
        ideaVersion {
            sinceBuild = "242"
            untilBuild = provider { null }
        }
    }
    buildSearchableOptions = false
}

kotlin {
    jvmToolchain(17)
}
