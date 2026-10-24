# Android app update notice

The Android wrapper checks `https://nongtraionline.vercel.app/app-update.json` after the local game page opens. A higher `versionCode` shows a prompt with the release notes. Choosing the update button opens Google Play for Play-installed copies and the APK download URL for other installs. The app does not download or install an APK silently.

For each release:

1. Increase `versionCode` and `versionName` in `app/build.gradle.kts`, then build and sign the APK.
2. Publish the new APK at `https://nongtraionline.vercel.app/vuon-nho-android-moi.apk` (or update `apkDownloadUrl`).
3. Update `outputs/app-update.json` with the same version code/name and release notes. Keep the Play listing URL correct for Google Play distribution.
4. Deploy the APK and manifest together. The manifest's version must never exceed the version inside the downloadable APK.

If the manifest cannot be reached or is invalid, the game starts normally and no update prompt is shown.
