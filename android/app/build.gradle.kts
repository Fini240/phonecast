plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "de.finn.phonecast"
    compileSdk = 35
    defaultConfig {
        applicationId = "de.finn.phonecast"
        minSdk = 30
        targetSdk = 35
        versionCode = 19
        versionName = "0.7.1"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("org.lsposed.hiddenapibypass:hiddenapibypass:6.1")
    // QR pairing (Pairing.kt): Google's code scanner, runs in Play services, no camera permission
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
