package io.xmrand.wrapper;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;
import java.net.URI;
import java.util.Iterator;

/** The saved JSON is authoritative; the service never substitutes UI or lab defaults. */
public final class MinerConfig {
    public static final int MAX_BYTES = 256 * 1024;
    private MinerConfig() {}

    public static JSONObject defaults() throws JSONException {
        JSONObject pool = new JSONObject().put("url", "").put("user", "")
                .put("pass", "x").put("rig-id", "xmrand").put("tls", true)
                .put("enabled", true).put("keepalive", true).put("algo", "rx/0");
        return new JSONObject().put("pools", new JSONArray().put(pool))
                .put("cpu", new JSONObject().put("enabled", true).put("yield", true)
                        .put("max-threads-hint", 100).put("priority", 2))
                .put("randomx", new JSONObject().put("mode", "auto"))
                .put("donate-level", 1).put("autosave", false)
                .put("xmrand", new JSONObject().put("autostart", false)
                        .put("charging-only", false).put("pause-battery", 15)
                        .put("resume-battery", 40).put("max-temperature", 45));
    }

    public static JSONObject parse(String text) throws JSONException {
        if (text.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > MAX_BYTES)
            throw new JSONException("Configuration is larger than 256 KB.");
        JSONTokener parser = new JSONTokener(text);
        Object value = parser.nextValue();
        if (!(value instanceof JSONObject) || parser.nextClean() != 0)
            throw new JSONException("Import one JSON object, without trailing data.");
        JSONObject config = (JSONObject) value;
        validate(config, false);
        return config;
    }

    public static JSONObject preferences(JSONObject config) throws JSONException {
        if (!config.has("xmrand")) config.put("xmrand", defaults().getJSONObject("xmrand"));
        return config.getJSONObject("xmrand");
    }

    public static void validate(JSONObject config, boolean ready) throws JSONException {
        JSONArray pools = config.getJSONArray("pools");
        if (pools.length() == 0 || pools.length() > 32) throw new JSONException("Use 1 to 32 pools.");
        int enabled = 0;
        for (int i = 0; i < pools.length(); i++) {
            JSONObject pool = pools.getJSONObject(i);
            String url = string(pool, "url", "");
            String user = string(pool, "user", "");
            string(pool, "pass", "x"); string(pool, "rig-id", ""); string(pool, "algo", "rx/0");
            bool(pool, "tls", false);
            boolean active = bool(pool, "enabled", true);
            if (!url.isEmpty()) validateEndpoint(url);
            if (active) {
                enabled++;
                if (ready && (url.isEmpty() || user.isEmpty() || user.startsWith("YOUR_")))
                    throw new JSONException("Enter your pool address and wallet/account for every enabled pool.");
            }
        }
        if (ready && enabled == 0) throw new JSONException("Enable at least one pool.");
        JSONObject cpu = config.has("cpu") ? config.getJSONObject("cpu") : new JSONObject();
        boolean cpuEnabled = bool(cpu, "enabled", true);
        if (ready && !cpuEnabled) throw new JSONException("Enable CPU mining first.");
        if (cpu.has("priority") && !cpu.isNull("priority")) integer(cpu, "priority", 2, 0, 5);
        integer(cpu, "max-threads-hint", 100, 1, 100);
        for (Iterator<String> it = cpu.keys(); it.hasNext();) {
            Object profile = cpu.get(it.next());
            if (profile instanceof JSONObject && ((JSONObject) profile).has("threads"))
                integer((JSONObject) profile, "threads", 1, 1, 256);
        }
        JSONObject randomx = config.has("randomx") ? config.getJSONObject("randomx") : new JSONObject();
        String mode = string(randomx, "mode", "auto");
        if (!mode.equals("auto") && !mode.equals("fast") && !mode.equals("light"))
            throw new JSONException("RandomX mode must be auto, fast or light.");
        integer(config, "donate-level", 1, 1, 100);
        JSONObject prefs = preferences(config);
        int pause = integer(prefs, "pause-battery", 15, 1, 98);
        int resume = integer(prefs, "resume-battery", 40, 2, 100);
        if (resume <= pause) throw new JSONException("Resume battery must be higher than pause battery.");
        integer(prefs, "max-temperature", 45, 30, 60);
        bool(prefs, "charging-only", false); bool(prefs, "autostart", false);
    }

    public static void validateEndpoint(String value) throws JSONException {
        try {
            if (value.matches(".*\\s.*")) throw new IllegalArgumentException();
            URI uri = new URI(value.contains("://") ? value : "stratum+tcp://" + value);
            String scheme = uri.getScheme();
            if (!(scheme.equals("stratum+tcp") || scheme.equals("stratum+ssl")
                    || scheme.equals("stratum+tls") || scheme.equals("tcp") || scheme.equals("ssl") || scheme.equals("tls")))
                throw new IllegalArgumentException();
            if (uri.getHost() == null || uri.getPort() < 1 || uri.getPort() > 65535
                    || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null
                    || (uri.getPath() != null && !uri.getPath().isEmpty())) throw new IllegalArgumentException();
        } catch (Exception e) { throw new JSONException("Pool address must be host:port (IPv6: [address]:port), without a wallet or path."); }
    }

    public static JSONObject runtime(JSONObject saved) throws JSONException {
        validate(saved, true);
        JSONObject runtime = new JSONObject(saved.toString());
        runtime.remove("xmrand");
        runtime.put("autosave", false).put("background", false).put("colors", false);
        runtime.remove("log-file");
        return runtime;
    }

    public static int integer(JSONObject object, String key, int fallback, int min, int max) throws JSONException {
        if (!object.has(key)) return fallback;
        Object v = object.get(key);
        if (!(v instanceof Number) || ((Number) v).doubleValue() != ((Number) v).intValue())
            throw new JSONException(key + " must be a whole number.");
        int n = ((Number) v).intValue();
        if (n < min || n > max) throw new JSONException(key + " must be between " + min + " and " + max + ".");
        return n;
    }

    public static String string(JSONObject object, String key, String fallback) throws JSONException {
        if (!object.has(key)) return fallback;
        Object v = object.get(key);
        if (!(v instanceof String) || ((String) v).matches("(?s).*[\\x00-\\x1f].*"))
            throw new JSONException(key + " must be text without control characters.");
        return (String) v;
    }

    public static boolean bool(JSONObject object, String key, boolean fallback) throws JSONException {
        if (!object.has(key)) return fallback;
        if (!(object.get(key) instanceof Boolean)) throw new JSONException(key + " must be true or false.");
        return object.getBoolean(key);
    }
}
