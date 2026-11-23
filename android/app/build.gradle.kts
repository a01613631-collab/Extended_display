plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.jose.tabdisplay"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.jose.tabdisplay"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            // Uso personal: se firma con la llave de debug para poder instalarla con adb.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // Solo pruebas: la app no tiene dependencias de terceros.
    testImplementation("junit:junit:4.13.2")
    // org.json del android.jar es un stub en pruebas locales; esta es la implementación real.
    testImplementation("org.json:json:20260814")
}
