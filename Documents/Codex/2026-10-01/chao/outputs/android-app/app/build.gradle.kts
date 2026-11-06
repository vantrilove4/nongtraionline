plugins { id("com.android.application") }

android {
    namespace = "com.vuonnho.mobile"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.vuonnho.mobile"
        minSdk = 23
        targetSdk = 34
        versionCode = 5
        versionName = "1.4"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
