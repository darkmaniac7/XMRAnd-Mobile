package io.xmrand.wrapper;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.os.BatteryManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import org.json.JSONArray;
import org.json.JSONObject;

public class MinerService extends Service {
    public static final String ACTION_START = "io.xmrand.wrapper.START";
    public static final String ACTION_RESTART = "io.xmrand.wrapper.RESTART";
    public static final String ACTION_STOP = "io.xmrand.wrapper.STOP";
    public static final String ACTION_WAIT = "io.xmrand.wrapper.WAIT";
    public static final String ACTION_STATUS = "io.xmrand.wrapper.STATUS";
    public static final String EXTRA_POOL = "pool";
    public static final String EXTRA_PORT = "port";
    public static final String EXTRA_LOG = "log";
    public static final String EXTRA_STATUS = "status";

    private static final String CHANNEL_ID = "miner";
    private static final int NOTIFICATION_ID = 42;
    private static final String CONFIG_NAME = "config.json";
    private static final int LOG_TAIL_BYTES = 32 * 1024;
    private static final int LOG_KEEP_BYTES = 256 * 1024;
    private static final long MAX_LOG_BYTES = 512L * 1024L;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Object lock = new Object();
    private final Object logLock = new Object();
    private final BroadcastReceiver idleReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            evaluateIdleState();
        }
    };

    private Process process;
    private PowerManager.WakeLock wakeLock;
    private boolean waitForIdle;
    private boolean receiverRegistered;
    private String pool = "";
    private String port = "";
    private String status = "Stopped";
    private String sensitiveUser = "";
    private File logFile;
    private JSONObject activeConfig;
    private PowerPolicy powerPolicy = new PowerPolicy();
    private String powerPause = "";
    private final android.os.Handler policyHandler = new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable policyTick = new Runnable() {
        @Override public void run() {
            evaluateIdleState();
            if (minerRequested) policyHandler.postDelayed(this, 15000);
        }
    };

    private MinerProcessControl minerControl;
    private volatile boolean minerRequested;

    @Override
    public void onCreate() {
        super.onCreate();
        logFile = new File(getFilesDir(), "miner.log");
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_STOP : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            waitForIdle = false;
            minerRequested = false;
            policyHandler.removeCallbacks(policyTick);
            unregisterIdleReceiver();
            stopMiner("Stopped by user.");
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        if (ACTION_STATUS.equals(action)) {
            broadcastLog();
            synchronized (lock) {
                if (!minerRequested && (process == null || !process.isAlive())) {
                    stopSelf(startId);
                }
            }
            return START_NOT_STICKY;
        }

        if (!ACTION_START.equals(action) && !ACTION_RESTART.equals(action) && !ACTION_WAIT.equals(action)) return START_NOT_STICKY;
        if (ACTION_START.equals(action) && minerRequested) { updateStatus(status); broadcastLog(); return START_NOT_STICKY; }
        try {
            JSONObject candidate = new ConfigStore(this).load();
            JSONObject runtime = MinerConfig.runtime(candidate);
            android.util.AtomicFile runtimeFile = new android.util.AtomicFile(new File(getFilesDir(), "runtime.json"));
            java.io.FileOutputStream output = null;
            try {
                output = runtimeFile.startWrite();
                output.write(runtime.toString().getBytes(StandardCharsets.UTF_8));
                runtimeFile.finishWrite(output);
            } catch (Exception failure) {
                if (output != null) runtimeFile.failWrite(output);
                throw failure;
            }
            stopMiner("Applying saved settings.");
            activeConfig = candidate;
        } catch (Exception e) {
            updateStatus("Settings need attention: " + e.getMessage());
            if (!minerRequested) stopSelf();
            return START_NOT_STICKY;
        }
        powerPolicy = new PowerPolicy();
        waitForIdle = ACTION_WAIT.equals(action);
        minerRequested = true;

        startMinerForeground(waitForIdle ? "Waiting for idle" : "Starting");
        registerIdleReceiver();
        policyHandler.removeCallbacks(policyTick);
        policyHandler.post(policyTick);
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        minerRequested = false;
        policyHandler.removeCallbacks(policyTick);
        unregisterIdleReceiver();
        stopMiner("Service destroyed.");
        io.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        handleForegroundTimeout(startId);
    }

    @Override
    public void onTimeout(int startId) {
        handleForegroundTimeout(startId);
    }

    // The miner runs as a specialUse foreground service, which is NOT subject to the
    // Android 15+ dataSync/mediaProcessing 6h-per-24h cap, so this callback is not
    // expected to fire. It is a defensive fallback: if the platform ever does time the
    // service out, refresh the foreground state and keep mining instead of dying, so a
    // fleet device never silently stops hashing and needs a manual relaunch. Only if the
    // platform refuses the refresh (a genuine, non-resettable cap) do we stop cleanly,
    // which still satisfies the OS contract and avoids the crash.
    private void handleForegroundTimeout(int startId) {
        try {
            startMinerForeground(status);
            synchronized (lock) {
                if ((process == null || !process.isAlive()) && !waitForIdle) {
                    appendLog("Foreground service timeout fired; refreshed and resuming miner.");
                    startMiner();
                } else {
                    appendLog("Foreground service timeout fired; refreshed, miner continues.");
                }
            }
        } catch (Exception e) {
            appendLog("Foreground refresh refused (" + e + "); stopping cleanly.");
            waitForIdle = false;
            unregisterIdleReceiver();
            stopMiner("Stopped after foreground service timeout.");
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf(startId);
        }
    }

    private void evaluateIdleState() {
        if (!minerRequested || activeConfig == null) {
            return;
        }
        Intent battery = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        int level = battery == null ? -1 : battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        int scale = battery == null ? -1 : battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
        int percent = level >= 0 && scale > 0 ? level * 100 / scale : -1;
        int temperature = battery == null ? 0 : battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0);
        boolean plugged = battery != null && battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
        JSONObject prefs = activeConfig.optJSONObject("xmrand");
        powerPause = powerPolicy.update(percent, temperature, plugged,
                prefs.optBoolean("charging-only", false), prefs.optInt("pause-battery", 15),
                prefs.optInt("resume-battery", 40), prefs.optInt("max-temperature", 45));
        if (miningAllowed()) {
            startMiner();
        } else {
            stopMiner(powerPause.isEmpty() ? "Waiting for idle." : powerPause);
            updateStatus(idleStatusText());
        }
    }

    private boolean miningAllowed() {
        boolean idlePaused = !powerPause.isEmpty() || (waitForIdle && !isIdleAllowed());
        return !idlePaused;
    }

    private String idleStatusText() {
        if (!powerPause.isEmpty() && minerRequested) return powerPause;
        return waitForIdle ? "Waiting for idle" : "Stopped";
    }

    private boolean isIdleAllowed() {
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        boolean screenOff = pm == null || !pm.isInteractive();
        Intent battery = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        int plugged = battery == null ? 0 : battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
        return screenOff || plugged != 0;
    }

    private void startMiner() {
        synchronized (lock) {
            if (!minerRequested || !miningAllowed()) {
                updateStatus(idleStatusText());
                return;
            }
            if (process != null && process.isAlive()) {
                updateStatus("Running");
                return;
            }
            reapOrphanedMiners();
            File config = new File(getFilesDir(), "runtime.json");
            if (!config.isFile() || activeConfig == null) {
                updateStatus("Save a valid configuration first.");
                return;
            }

            File xmrig = new File(getApplicationInfo().nativeLibraryDir, "libxmrig.so");
            if (!xmrig.canExecute()) {
                appendLog("Missing executable: " + xmrig.getAbsolutePath());
                updateStatus("Missing xmrig binary");
                return;
            }

            refreshSensitiveUser(config, "");

            List<String> cmd = new ArrayList<>();
            cmd.add(xmrig.getAbsolutePath());
            cmd.add("--config=" + config.getAbsolutePath());
            cmd.add("--no-color");
            cmd.add("--print-time=15");

            try {
                acquireWakeLock();
                ProcessBuilder pb = new ProcessBuilder(cmd);
                pb.directory(getFilesDir());
                pb.redirectErrorStream(true);
                pb.environment().put("HOME", getFilesDir().getAbsolutePath());
                process = pb.start();
                appendLog("Started: " + redactedCommand(cmd));
                updateStatus("Running");
                Process launched = process;
                io.execute(() -> readProcessOutput(launched));
            } catch (IOException e) {
                releaseWakeLock();
                appendLog("Start failed: " + e);
                updateStatus("Start failed");
            }
        }
    }

    private String redactedCommand(List<String> cmd) {
        List<String> redacted = new ArrayList<>(cmd);
        for (int i = 0; i < redacted.size() - 1; i++) {
            if ("-u".equals(redacted.get(i)) || "--user".equals(redacted.get(i))) {
                redacted.set(i + 1, "<redacted>");
            }
        }
        return String.join(" ", redacted);
    }

    private void refreshSensitiveUser(File config, String cliUser) {
        String value = cliUser == null ? "" : cliUser;
        if (config.isFile()) {
            try {
                JSONObject root = new JSONObject(new String(Files.readAllBytes(config.toPath()), StandardCharsets.UTF_8));
                JSONArray pools = root.optJSONArray("pools");
                if (pools != null && pools.length() > 0) {
                    String configured = pools.getJSONObject(0).optString("user", "");
                    if (!configured.isEmpty()) {
                        value = configured;
                    }
                }
            } catch (Exception ignored) {
            }
        }
        sensitiveUser = value;
    }

    private String redactSensitive(String line) {
        if (line == null) {
            return "";
        }
        String user = sensitiveUser;
        if (user == null || user.length() < 8) {
            return line;
        }
        return line.replace(user, "<redacted>");
    }

    private void readProcessOutput(Process running) {
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(running.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                appendLog(line);
            }
            int exit = running.waitFor();
            appendLog("xmrig exited with code " + exit);
        } catch (Exception e) {
            appendLog("xmrig output reader stopped: " + e);
        } finally {
            synchronized (lock) {
                if (process == running) {
                    process = null;
                    releaseWakeLock();
                    updateStatus(idleStatusText());
                }
            }
        }
    }

    private void stopMiner(String reason) {
        Process toStop;
        synchronized (lock) {
            toStop = process;
            process = null;
        }
        if (toStop != null) {
            appendLog(reason);
            // A SIGSTOPped process does not act on the SIGTERM that destroy() sends
            // until it is running again, so continue it first. Without this, every
            // stop of a paused miner would burn the full destroyForcibly timeout,
            // and a service teardown could leave a frozen process behind.
            thawBeforeStopping();
            toStop.destroy();
            try {
                if (!toStop.waitFor(3, TimeUnit.SECONDS)) {
                    toStop.destroyForcibly();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                toStop.destroyForcibly();
            }
        } else if (reason != null && !reason.startsWith("Service")) {
            appendLog(reason);
        }
        releaseWakeLock();
        updateStatus(idleStatusText());
    }

    private synchronized MinerProcessControl minerControl() {
        if (minerControl == null) {
            minerControl = new MinerProcessControl(
                    new MinerProcessControl.RealProcTable(),
                    new MinerProcessControl.RealSignaller(),
                    new MinerProcessControl.RealSleeper(),
                    android.os.Process.myPid(),
                    new File(getApplicationInfo().nativeLibraryDir, "libxmrig.so").getAbsolutePath());
        }
        return minerControl;
    }

    /**
     * Thaws the miner so that the SIGTERM from destroy() can actually be delivered.
     *
     * <p>This deliberately does not check whether we believe the miner is paused.
     * The dangerous case is precisely the one where that belief is wrong or has
     * already been cleared, for example a service teardown that shuts the watcher
     * down first. SIGCONT to a process that is already running is a no-op, so the
     * unconditional attempt costs nothing and removes a whole class of leaked
     * frozen miners.
     */
    private void thawBeforeStopping() {
        try {
            minerControl().resume();
        } catch (RuntimeException ignored) {
            // Best effort. destroyForcibly still ends the process either way.
        }
    }

    /**
     * Clears any miner left frozen by a previous run of this service. If the process
     * is killed while the miner is SIGSTOPped, the miner is reparented and stays
     * stopped forever holding its dataset, so it has to be continued and killed
     * before a new one is started.
     */
    private void reapOrphanedMiners() {
        try {
            int reaped = minerControl().cleanUpOrphans();
            if (reaped > 0) {
                appendLog("Cleared " + reaped + " miner process(es) left over from a previous run.");
            }
        } catch (RuntimeException e) {
            appendLog("Orphan miner cleanup failed: " + e);
        }
    }

    private int batteryTempDecic() {
        Intent battery = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        return battery == null ? 0 : battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0);
    }

    private void acquireWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            return;
        }
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (pm == null) {
            return;
        }
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "XMRAnd:Miner");
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire();
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
    }

    private void appendLog(String line) {
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date());
        String entry = stamp + " " + redactSensitive(line) + "\n";
        synchronized (logLock) {
            try (FileOutputStream out = new FileOutputStream(logFile, true)) {
                out.write(entry.getBytes(StandardCharsets.UTF_8));
            } catch (IOException ignored) {
            }
            try {
                trimLogIfNeededLocked();
            } catch (IOException ignored) {
            }
        }
        broadcastLog();
    }

    private void broadcastLog() {
        String text = "";
        synchronized (logLock) {
            try {
                text = readLogTailLocked(LOG_TAIL_BYTES);
            } catch (IOException ignored) {
            }
        }
        sendBroadcast(new Intent(ACTION_STATUS)
                .setPackage(getPackageName())
                .putExtra(EXTRA_LOG, text)
                .putExtra(EXTRA_STATUS, status));
    }

    private void trimLogIfNeededLocked() throws IOException {
        if (logFile == null || !logFile.isFile() || logFile.length() <= MAX_LOG_BYTES) {
            return;
        }
        String tail = readLogTailLocked(LOG_KEEP_BYTES);
        String header = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date())
                + " miner.log rotated; showing recent output only.\n";
        try (FileOutputStream out = new FileOutputStream(logFile, false)) {
            out.write(header.getBytes(StandardCharsets.UTF_8));
            out.write(tail.getBytes(StandardCharsets.UTF_8));
        }
    }

    private String readLogTailLocked(int maxBytes) throws IOException {
        if (logFile == null || !logFile.isFile()) {
            return "";
        }
        try (RandomAccessFile raf = new RandomAccessFile(logFile, "r")) {
            long length = raf.length();
            int bytesToRead = (int) Math.min(maxBytes, length);
            long start = Math.max(0, length - bytesToRead);
            byte[] bytes = new byte[bytesToRead];
            raf.seek(start);
            raf.readFully(bytes);
            String text = new String(bytes, StandardCharsets.UTF_8);
            if (start > 0) {
                return "... showing last " + (bytesToRead / 1024) + " KiB of miner.log ...\n" + text;
            }
            return text;
        }
    }

    private void updateStatus(String value) {
        status = value;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.notify(NOTIFICATION_ID, buildNotification(value));
        }
        broadcastLog();
    }

    private Notification buildNotification(String text) {
        Intent open = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pending = PendingIntent.getActivity(
                this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return builder
                .setContentTitle("XMRAnd")
                .setContentText(text == null ? status : text)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentIntent(pending)
                .setOngoing(process != null || waitForIdle)
                .build();
    }

    private void startMinerForeground(String text) {
        Notification notification = buildNotification(text);
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "Miner", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Visible foreground miner status");
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.createNotificationChannel(channel);
        }
    }

    private void registerIdleReceiver() {
        if (receiverRegistered) {
            return;
        }
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_POWER_CONNECTED);
        filter.addAction(Intent.ACTION_POWER_DISCONNECTED);
        filter.addAction(Intent.ACTION_BATTERY_CHANGED);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(idleReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(idleReceiver, filter);
        }
        receiverRegistered = true;
    }

    private void unregisterIdleReceiver() {
        if (!receiverRegistered) {
            return;
        }
        unregisterReceiver(idleReceiver);
        receiverRegistered = false;
    }
}
