package io.xmrand.wrapper;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

public final class ConfigStore {
    private final AtomicFile file;
    public ConfigStore(Context context) { file = new AtomicFile(new File(context.getFilesDir(), "config.json")); }
    public JSONObject load() throws Exception {
        try (java.io.InputStream in = file.openRead(); java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096]; int n;
            while ((n = in.read(buffer)) != -1) {
                if (out.size() + n > MinerConfig.MAX_BYTES) throw new IllegalArgumentException("Configuration is larger than 256 KB.");
                out.write(buffer, 0, n);
            }
            return MinerConfig.parse(new String(out.toByteArray(), StandardCharsets.UTF_8));
        } catch (java.io.FileNotFoundException missing) {
            if (file.getBaseFile().exists()) throw missing;
            return MinerConfig.defaults();
        }
    }
    public void save(JSONObject config) throws Exception {
        MinerConfig.validate(config, false);
        byte[] bytes = config.toString(2).getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MinerConfig.MAX_BYTES) throw new IllegalArgumentException("Configuration is larger than 256 KB.");
        FileOutputStream stream = null;
        try { stream = file.startWrite(); stream.write(bytes); file.finishWrite(stream); }
        catch (Exception e) { if (stream != null) file.failWrite(stream); throw e; }
    }
}
