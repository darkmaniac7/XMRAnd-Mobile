package io.xmrand.wrapper;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.*;
import android.net.Uri;
import android.os.*;
import android.provider.Settings;
import android.text.InputType;
import android.view.ViewGroup;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

public class MainActivity extends Activity {
    private final Map<String, EditText> fields = new LinkedHashMap<>();
    private JSONObject profile;
    private ConfigStore store;
    private Switch tls, charging, autostart;
    private TextView status, log;
    private LinearLayout form;
    private boolean registered;
    private byte[] pendingExport;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            if (i.hasExtra(MinerService.EXTRA_STATUS)) status.setText(i.getStringExtra(MinerService.EXTRA_STATUS));
            if (i.hasExtra(MinerService.EXTRA_LOG)) log.setText(i.getStringExtra(MinerService.EXTRA_LOG));
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        setTitle("XMRAnd"); store = new ConfigStore(this);
        String loadError = null;
        try { profile = store.load(); }
        catch (Exception e) { loadError = "Saved configuration could not be read. Import a valid configuration or correct the fields before saving."; }
        try { if (profile == null) profile = MinerConfig.defaults(); }
        catch (JSONException e) { throw new IllegalStateException(e); }
        form = new LinearLayout(this); form.setOrientation(LinearLayout.VERTICAL);
        int pad = Math.round(16 * getResources().getDisplayMetrics().density); form.setPadding(pad, pad, pad, pad);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.addView(form); setContentView(scroll);
        text("Your wallet. Your pool. Mining starts only when you choose Start or enable automatic start.");
        button("Setup and how-to", this::guide);
        field("url", "Pool address (host:port)", false);
        field("user", "Wallet / pool account", false);
        field("pass", "Pool password (usually x)", false).setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        field("worker", "Worker / rig name", false);
        tls = toggle("TLS connection");
        field("backups", "Backup pools, one host:port per line (advanced JSON supports separate logins)", true);
        field("algo", "Algorithm (rx/0 for Monero; must be supported by this build)", false);
        field("threads", "CPU threads: 0 = automatic, custom = advanced profile", false);
        field("priority", "CPU priority: 0 (lowest) to 5 (highest), auto = default", false);
        field("mode", "RandomX memory: auto, fast (~2 GB), light (slower)", false);
        field("donate", "XMRig developer donation (%) — minimum 1", false);
        charging = toggle("Mine only while charging");
        field("pause", "Pause below battery (%)", false);
        field("resume", "Resume at battery (%)", false);
        field("temperature", "Pause at battery temperature (°C, 30–60; resumes 3°C lower)", false);
        autostart = toggle("Start automatically when I open XMRAnd");
        button("Save settings", () -> save(false));
        button("Start / apply and restart", () -> { if (save(true)) action(MinerService.ACTION_RESTART); });
        button("Stop", () -> action(MinerService.ACTION_STOP));
        button("Wait for idle", () -> { if (save(true)) action(MinerService.ACTION_WAIT); });
        button("Advanced JSON", this::advanced);
        button("Import JSON", () -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .setType("*/*").addCategory(Intent.CATEGORY_OPENABLE), 10));
        button("Export JSON", this::export);
        button("Notification permission", () -> { if (Build.VERSION.SDK_INT >= 33) requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 1); });
        button("Battery optimization settings", () -> {
            try { startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName()))); }
            catch (RuntimeException e) { message("Open Android Settings → Apps → XMRAnd → Battery and allow unrestricted background use."); }
        });
        status = text("Stopped"); status.setTextIsSelectable(true);
        log = text(""); log.setTextSize(12); log.setTextIsSelectable(true);
        render();
        if (loadError != null) message(loadError);
        else if (profile.optJSONObject("xmrand").optBoolean("autostart", false)) {
            try { MinerConfig.validate(profile, true); action(MinerService.ACTION_START); }
            catch (Exception e) { message(e.getMessage()); }
        }
    }

    private TextView text(String value) { TextView view = new TextView(this); view.setText(value); view.setPadding(0, 10, 0, 4); form.addView(view); return view; }
    private EditText field(String key, String label, boolean multi) {
        text(label); EditText view = new EditText(this); view.setSingleLine(!multi);
        view.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS | (multi ? InputType.TYPE_TEXT_FLAG_MULTI_LINE : 0));
        view.setContentDescription(label); view.setTag(key); fields.put(key, view); form.addView(view); return view;
    }
    private Switch toggle(String label) { Switch view = new Switch(this); view.setText(label); form.addView(view); return view; }
    private void button(String label, Runnable callback) { Button b = new Button(this); b.setText(label); b.setOnClickListener(v -> callback.run()); form.addView(b); }
    private String value(String key) { return fields.get(key).getText().toString().trim(); }
    private int number(String key) throws JSONException {
        try { return Integer.parseInt(value(key)); } catch (NumberFormatException e) { throw new JSONException(key + " must be a whole number."); }
    }
    private void put(String key, Object value) { fields.get(key).setText(String.valueOf(value)); }
    private void render() {
        try {
            JSONObject pool = profile.getJSONArray("pools").getJSONObject(0);
            put("url", pool.optString("url", "")); put("user", pool.optString("user", ""));
            put("pass", pool.optString("pass", "x")); put("worker", pool.optString("rig-id", ""));
            tls.setChecked(pool.optBoolean("tls", false)); put("algo", pool.optString("algo", "rx/0"));
            StringBuilder backups = new StringBuilder();
            JSONArray pools = profile.getJSONArray("pools");
            for (int i = 1; i < pools.length(); i++) { if (i > 1) backups.append('\n'); backups.append(pools.getJSONObject(i).optString("url", "")); }
            put("backups", backups);
            JSONObject cpu = profile.optJSONObject("cpu"); if (cpu == null) cpu = new JSONObject();
            Object threads = cpu.opt(pool.optString("algo", "rx/0"));
            put("threads", threads == null ? 0 : threads instanceof JSONObject ? ((JSONObject) threads).optInt("threads", 0) : "custom");
            put("priority", cpu.has("priority") && cpu.isNull("priority") ? "auto" : cpu.optInt("priority", 2));
            JSONObject rx = profile.optJSONObject("randomx"); put("mode", rx == null ? "auto" : rx.optString("mode", "auto"));
            put("donate", profile.optInt("donate-level", 1));
            JSONObject prefs = MinerConfig.preferences(profile);
            put("pause", prefs.optInt("pause-battery", 15)); put("resume", prefs.optInt("resume-battery", 40));
            put("temperature", prefs.optInt("max-temperature", 45)); charging.setChecked(prefs.optBoolean("charging-only", false)); autostart.setChecked(prefs.optBoolean("autostart", false));
        } catch (Exception e) { message(e.getMessage()); }
    }

    private JSONObject fromForm() throws Exception {
        JSONObject next = new JSONObject(profile.toString());
        JSONArray oldPools = next.getJSONArray("pools"); JSONObject pool = oldPools.getJSONObject(0);
        JSONObject previous = new JSONObject(pool.toString());
        pool.put("url", value("url")).put("user", value("user")).put("pass", fields.get("pass").getText().toString())
                .put("rig-id", value("worker")).put("tls", tls.isChecked()).put("algo", value("algo"));
        JSONArray pools = new JSONArray().put(pool);
        for (String url : value("backups").split("\\R")) {
            url = url.trim(); if (url.isEmpty()) continue;
            JSONObject backup = null;
            for (int i = 1; i < oldPools.length(); i++) if (url.equals(oldPools.getJSONObject(i).optString("url"))) backup = new JSONObject(oldPools.getJSONObject(i).toString());
            if (backup == null) backup = new JSONObject(pool.toString()).put("url", url);
            else for (String key : new String[]{"user", "pass", "rig-id", "tls", "algo"}) {
                if (java.util.Objects.equals(backup.opt(key), previous.opt(key))) backup.put(key, pool.get(key));
            }
            pools.put(backup);
        }
        next.put("pools", pools);
        JSONObject cpu = next.optJSONObject("cpu"); if (cpu == null) cpu = new JSONObject();
        if (!value("threads").equals("custom")) {
            int count = number("threads");
            if (count < 0 || count > Runtime.getRuntime().availableProcessors()) throw new JSONException("Threads must be 0 to " + Runtime.getRuntime().availableProcessors() + ".");
            if (count == 0) cpu.remove(value("algo"));
            else {
                JSONObject tuning = cpu.optJSONObject(value("algo")); if (tuning == null) tuning = new JSONObject().put("intensity", 1).put("affinity", -1);
                tuning.put("threads", count); cpu.put(value("algo"), tuning);
            }
        }
        cpu.put("priority", value("priority").equals("auto") ? JSONObject.NULL : number("priority")); next.put("cpu", cpu);
        JSONObject rx = next.optJSONObject("randomx"); if (rx == null) rx = new JSONObject();
        rx.put("mode", value("mode")); next.put("randomx", rx).put("donate-level", number("donate"));
        MinerConfig.preferences(next).put("pause-battery", number("pause")).put("resume-battery", number("resume"))
                .put("max-temperature", number("temperature")).put("charging-only", charging.isChecked()).put("autostart", autostart.isChecked());
        return next;
    }
    private boolean save(boolean ready) {
        try { JSONObject next = fromForm(); MinerConfig.validate(next, ready); store.save(next); profile = next; status.setText("Saved. Start / apply restarts mining with these settings."); return true; }
        catch (Exception e) { message(e.getMessage()); return false; }
    }
    private void advanced() {
        try {
            JSONObject next = fromForm(); EditText editor = new EditText(this);
            editor.setText(next.toString(2)); editor.setGravity(android.view.Gravity.TOP); editor.setMinLines(12);
            editor.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
            ScrollView scroll = new ScrollView(this); scroll.addView(editor);
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Advanced XMRig JSON")
                    .setMessage("Unknown engine options are preserved. Saving applies on the next Start. Profiles may contain pool passwords or API tokens.")
                    .setView(scroll).setNegativeButton("Cancel", null).setPositiveButton("Save", null).create();
            dialog.setOnShowListener(v -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(b -> {
                try { JSONObject parsed = MinerConfig.parse(editor.getText().toString()); store.save(parsed); profile = parsed; render(); dialog.dismiss(); }
                catch (Exception e) { editor.setError(e.getMessage()); }
            })); dialog.show();
        } catch (Exception e) { message(e.getMessage()); }
    }
    private void export() {
        if (!save(false)) return;
        new AlertDialog.Builder(this).setTitle("Export private configuration?")
                .setMessage("This includes your wallet/account, pool passwords and any advanced API credentials. Share only after removing private values.")
                .setNegativeButton("Cancel", null).setPositiveButton("Choose file", (d, w) -> {
                    pendingExport = profile.toString().getBytes(StandardCharsets.UTF_8);
                    startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/json")
                            .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, "xmrand-config.json"), 11);
                }).show();
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        try {
            if (request == 10) {
                byte[] bytes;
                try (InputStream in = getContentResolver().openInputStream(data.getData()); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[4096]; int n;
                    while ((n = in.read(buffer)) != -1) { if (out.size() + n > MinerConfig.MAX_BYTES) throw new IOException("File exceeds 256 KB."); out.write(buffer, 0, n); }
                    bytes = out.toByteArray();
                }
                JSONObject imported = MinerConfig.parse(new String(bytes, StandardCharsets.UTF_8));
                new AlertDialog.Builder(this).setTitle("Replace saved settings?")
                        .setMessage("Review the wallet and pools after import. Mining will not start automatically from an import.")
                        .setNegativeButton("Cancel", null).setPositiveButton("Import", (d, w) -> {
                            try { MinerConfig.preferences(imported).put("autostart", false); store.save(imported); profile = imported; render(); status.setText("Imported. Review settings, then Start."); }
                            catch (Exception e) { message(e.getMessage()); }
                        }).show();
            } else if (request == 11 && pendingExport != null) {
                try (OutputStream out = getContentResolver().openOutputStream(data.getData(), "wt")) { out.write(pendingExport); }
                pendingExport = null; status.setText("Configuration exported.");
            }
        } catch (Exception e) { message(e.getMessage()); }
    }
    private void guide() {
        android.webkit.WebView view = new android.webkit.WebView(this); view.loadUrl("file:///android_asset/public-setup.html");
        new AlertDialog.Builder(this).setTitle("XMRAnd setup").setView(view).setPositiveButton("Close", null).show();
    }
    private void message(String text) { new AlertDialog.Builder(this).setTitle("XMRAnd").setMessage(text == null ? "Configuration could not be read." : text).setPositiveButton("OK", null).show(); }
    private void action(String action) {
        Intent intent = new Intent(this, MinerService.class).setAction(action);
        try {
            if (Build.VERSION.SDK_INT >= 26 && !action.equals(MinerService.ACTION_STOP) && !action.equals(MinerService.ACTION_STATUS)) startForegroundService(intent);
            else startService(intent);
        } catch (RuntimeException e) { message("Android could not start the service. Check the notification and battery permissions, then retry while XMRAnd is open."); }
    }
    @Override protected void onResume() {
        super.onResume(); IntentFilter filter = new IntentFilter(MinerService.ACTION_STATUS);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED); else registerReceiver(receiver, filter);
        registered = true; action(MinerService.ACTION_STATUS);
    }
    @Override protected void onPause() { if (registered) { unregisterReceiver(receiver); registered = false; } super.onPause(); }
}
