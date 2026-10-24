package com.vuonnho.mobile;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.net.Uri;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

public final class MainActivity extends Activity {
    private WebView webView;
    private static final String APP_HOST = "appassets.androidplatform.net";
    private static final String UPDATE_MANIFEST_URL = "https://nongtraionline.vercel.app/app-update.json";
    private static final String APK_DOWNLOAD_URL = "https://nongtraionline.vercel.app/vuon-nho-android-moi.apk";
    private static final String PLAY_STORE_URL = "https://play.google.com/store/apps/details?id=com.vuonnho.mobile";
    private boolean updateCheckStarted;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        enterImmersiveMode();
        webView = new WebView(this);
        webView.setBackgroundColor(0xffeaf1dc);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        webView.setWebViewClient(new WebViewClient() {
            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if (!"https".equals(uri.getScheme()) || !APP_HOST.equals(uri.getHost())) return super.shouldInterceptRequest(view, request);
                String path = uri.getPath();
                if (path == null || path.isEmpty() || "/".equals(path)) path = "/index.html";
                while (path.startsWith("/")) path = path.substring(1);
                if (path.contains("..")) return response(400, "Bad Request", "text/plain", null);
                try {
                    return new WebResourceResponse(mime(path), "UTF-8", getAssets().open("www/" + path));
                } catch (IOException e) {
                    return response(404, "Not Found", "text/plain", null);
                }
            }
            @Override public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                view.evaluateJavascript("(()=>{const s=document.querySelector('.scene');if(s)s.classList.add('game-fullscreen');document.documentElement.classList.add('game-fullscreen-active');const style=document.createElement('style');style.textContent='.wrap{max-width:none;width:100%;height:100dvh;margin:0;padding:0}.top{display:none}.scene{border:0;border-radius:0}.fullscreen-toggle{display:none!important}';document.head.appendChild(style)})()", null);
                if (!updateCheckStarted) {
                    updateCheckStarted = true;
                    new Handler(Looper.getMainLooper()).postDelayed(MainActivity.this::checkForAppUpdate, 1800);
                }
            }
        });
        setContentView(webView);
        webView.loadUrl("https://" + APP_HOST + "/index.html");
    }

    private void checkForAppUpdate() {
        Thread check = new Thread(() -> {
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(UPDATE_MANIFEST_URL).openConnection();
                connection.setRequestMethod("GET");
                connection.setConnectTimeout(4500);
                connection.setReadTimeout(4500);
                connection.setUseCaches(false);
                connection.setRequestProperty("Cache-Control", "no-cache");
                if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) return;
                try (InputStream input = connection.getInputStream(); java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
                    byte[] buffer = new byte[2048];
                    int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                    JSONObject manifest = new JSONObject(output.toString(StandardCharsets.UTF_8.name()));
                    int latestCode = manifest.optInt("versionCode", 0);
                    String latestName = manifest.optString("versionName", "").trim();
                    String notes = manifest.optString("releaseNotes", "").trim();
                    if (latestCode <= getPackageManager().getPackageInfo(getPackageName(), 0).versionCode) return;
                    String installer = getInstallerPackageNameCompat();
                    String target = "com.android.vending".equals(installer)
                            ? manifest.optString("playStoreUrl", PLAY_STORE_URL)
                            : manifest.optString("apkDownloadUrl", APK_DOWNLOAD_URL);
                    URL targetUrl = new URL(target);
                    if (!"https".equalsIgnoreCase(targetUrl.getProtocol())) return;
                    new Handler(Looper.getMainLooper()).post(() -> showUpdatePrompt(latestName, notes, targetUrl.toString()));
                }
            } catch (Exception ignored) {
                // Update checks are optional; network or manifest errors must not block startup.
            } finally {
                if (connection != null) connection.disconnect();
            }
        }, "farm-app-update-check");
        check.setDaemon(true);
        check.start();
    }

    private String getInstallerPackageNameCompat() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                android.content.pm.InstallSourceInfo info = getPackageManager().getInstallSourceInfo(getPackageName());
                return info.getInstallingPackageName();
            }
            //noinspection deprecation
            return getPackageManager().getInstallerPackageName(getPackageName());
        } catch (Exception ignored) {
            return null;
        }
    }

    private void showUpdatePrompt(String versionName, String releaseNotes, String targetUrl) {
        if (isFinishing() || isDestroyed()) return;
        String message = "Đã có phiên bản Vườn Nhỏ mới" + (versionName.isEmpty() ? "" : " " + versionName)
                + ". Bạn có muốn tải bản cập nhật không?";
        if (!releaseNotes.isEmpty()) message += "\n\n" + releaseNotes;
        new AlertDialog.Builder(this)
                .setTitle("🌱 Có bản cập nhật mới")
                .setMessage(message)
                .setNegativeButton("Để sau", null)
                .setPositiveButton("Tải bản cập nhật", (dialog, which) -> {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(targetUrl)));
                    } catch (Exception ignored) {
                        new AlertDialog.Builder(this).setMessage("Không mở được trang tải. Hãy thử lại khi có kết nối mạng.")
                                .setPositiveButton("Đóng", null).show();
                    }
                })
                .show();
    }

    private static WebResourceResponse response(int code, String reason, String mime, java.io.InputStream body) {
        Map<String,String> headers = new HashMap<>();
        headers.put("Access-Control-Allow-Origin", "*");
        return new WebResourceResponse(mime, "UTF-8", code, reason, headers, body);
    }
    private static String mime(String path) {
        String p = path.toLowerCase(Locale.ROOT);
        if (p.endsWith(".html")) return "text/html";
        if (p.endsWith(".js")) return "application/javascript";
        if (p.endsWith(".css")) return "text/css";
        if (p.endsWith(".png")) return "image/png";
        if (p.endsWith(".webp")) return "image/webp";
        if (p.endsWith(".jpg") || p.endsWith(".jpeg")) return "image/jpeg";
        if (p.endsWith(".svg")) return "image/svg+xml";
        if (p.endsWith(".json")) return "application/json";
        if (p.endsWith(".mp3")) return "audio/mpeg";
        if (p.endsWith(".ogg")) return "audio/ogg";
        if (p.endsWith(".wav")) return "audio/wav";
        return "application/octet-stream";
    }
    private void enterImmersiveMode() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }
    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) enterImmersiveMode();
    }
    @Override public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }
    @Override protected void onDestroy() {
        if (webView != null) { webView.loadUrl("about:blank"); webView.destroy(); webView = null; }
        super.onDestroy();
    }
}
