import java.awt.RenderingHints
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

abstract class GenerateLauncherIconsTask : DefaultTask() {
    @get:InputFile
    abstract val source: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun generate() {
        val sourceFile = source.get().asFile
        val sourceImage = ImageIO.read(sourceFile)
            ?: error("Cannot decode ${sourceFile.path}")
        val densities = mapOf(
            "mdpi" to 48,
            "hdpi" to 72,
            "xhdpi" to 96,
            "xxhdpi" to 144,
            "xxxhdpi" to 192,
        )
        val root = outputDir.get().asFile
        root.deleteRecursively()
        for ((density, size) in densities) {
            val target = File(root, "mipmap-$density/ic_launcher.png")
            target.parentFile.mkdirs()
            val icon = BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB)
            val canvas = icon.createGraphics()
            canvas.setRenderingHint(
                RenderingHints.KEY_INTERPOLATION,
                RenderingHints.VALUE_INTERPOLATION_BICUBIC,
            )
            canvas.drawImage(sourceImage, 0, 0, size, size, null)
            canvas.dispose()
            ImageIO.write(icon, "png", target)
        }
    }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nekoproxy.nekoproxy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.nekoproxy.nekoproxy"
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**")
        }
    }
}

androidComponents {
    onVariants { variant ->
        val taskName = "generate${variant.name.replaceFirstChar { it.uppercase() }}LauncherIcons"
        val generateTask = tasks.register<GenerateLauncherIconsTask>(taskName) {
            description = "Generate Android launcher icons from assets/icons/app_icon.png."
            source.set(rootProject.file("../assets/icons/app_icon.png"))
            outputDir.set(layout.buildDirectory.dir("generated/launcherIcons/${variant.name}"))
        }
        variant.sources.res?.addGeneratedSourceDirectory(
            generateTask,
            GenerateLauncherIconsTask::outputDir,
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/nekoproxy.aar"))
}
