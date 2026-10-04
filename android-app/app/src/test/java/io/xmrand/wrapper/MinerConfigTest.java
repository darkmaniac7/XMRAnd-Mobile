package io.xmrand.wrapper;
import org.junit.Test;
import org.json.*;
import static org.junit.Assert.*;
public class MinerConfigTest {
    private JSONObject ready() throws Exception {
        JSONObject c = MinerConfig.defaults();
        c.getJSONArray("pools").getJSONObject(0).put("url", "pool.example:443").put("user", "test-account");
        return c;
    }
    @Test public void freshInstallCannotMine() throws Exception {
        JSONObject c = MinerConfig.defaults();
        assertFalse(MinerConfig.preferences(c).getBoolean("autostart"));
        assertEquals("", c.getJSONArray("pools").getJSONObject(0).getString("user"));
        MinerConfig.validate(c, false);
        assertThrows(JSONException.class, () -> MinerConfig.runtime(c));
    }
    @Test public void runtimePreservesPoolsAndAdvancedOptionsWithoutMutatingSaved() throws Exception {
        JSONObject c = ready();
        c.getJSONArray("pools").put(new JSONObject().put("url","backup.example:1234").put("user","backup-account").put("tls",false));
        c.put("retries",7).put("log-file","/private/wrong");
        c.getJSONObject("cpu").put("rx/0",new JSONArray().put(0).put(2));
        String before = c.toString(); JSONObject r = MinerConfig.runtime(c);
        assertEquals(7,r.getInt("retries")); assertEquals(2,r.getJSONArray("pools").length());
        assertEquals("backup-account",r.getJSONArray("pools").getJSONObject(1).getString("user"));
        assertTrue(r.getJSONObject("cpu").get("rx/0") instanceof JSONArray);
        assertFalse(r.has("xmrand")); assertFalse(r.has("log-file")); assertEquals(before,c.toString());
    }
    @Test public void rejectsInvalidInputs() throws Exception {
        for (String endpoint : new String[]{"pool.example", "https://pool.example:443", "wallet@pool.example:80", "pool.example:0", "pool.example:65536", "pool.example:80/path", "pool.example:80?q=x"})
            assertThrows(endpoint,JSONException.class, () -> MinerConfig.validateEndpoint(endpoint));
        for (String endpoint : new String[]{"pool.example:443","[::1]:3333","stratum+ssl://pool.example:443"}) MinerConfig.validateEndpoint(endpoint);
        JSONObject c = ready(); c.getJSONObject("xmrand").put("resume-battery",15);
        assertThrows(JSONException.class, () -> MinerConfig.validate(c,true));
        c.getJSONObject("xmrand").put("resume-battery",40).put("autostart","false");
        assertThrows(JSONException.class, () -> MinerConfig.validate(c,true));
        assertThrows(JSONException.class, () -> MinerConfig.parse("{} garbage"));
        assertThrows(JSONException.class, () -> MinerConfig.parse("[]"));
        assertThrows(JSONException.class, () -> MinerConfig.parse(" ".repeat(MinerConfig.MAX_BYTES+1)));
    }
    @Test public void disabledPoolsDoNotAuthorizeMining() throws Exception {
        JSONObject c = ready();c.getJSONArray("pools").getJSONObject(0).put("enabled",false);
        assertThrows(JSONException.class, () -> MinerConfig.runtime(c));
    }
    @Test public void roundTripRetainsUserSettings() throws Exception {
        JSONObject c=ready(); c.getJSONObject("cpu").put("priority",JSONObject.NULL);
        c.getJSONObject("randomx").put("mode","light");
        JSONObject copy=MinerConfig.parse(c.toString()); MinerConfig.validate(copy,true);
        assertTrue(copy.getJSONObject("cpu").isNull("priority"));
        assertEquals("light",copy.getJSONObject("randomx").getString("mode"));
    }
}
