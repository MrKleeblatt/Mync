allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Plugins mit älterem festem compileSdk (audio_service, audio_session, jni_flutter: 35)
// gegen das compileSdk der App bauen, statt eine weitere SDK-Platform zu verlangen – in
// der Devshell liegt das SDK schreibgeschützt im Nix-Store und hat nur die der App.
// Vor evaluationDependsOn registriert, damit es vor AGPs eigenem afterEvaluate läuft.
subprojects {
    afterEvaluate {
        val library = extensions.findByType<com.android.build.api.dsl.LibraryExtension>()
            ?: return@afterEvaluate
        val appSdk = project(":app").extensions
            .getByType<com.android.build.api.dsl.ApplicationExtension>().compileSdk
            ?: return@afterEvaluate
        if ((library.compileSdk ?: 0) < appSdk) library.compileSdk = appSdk
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
