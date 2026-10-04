package io.xmrand.wrapper;
import android.app.Instrumentation;
import android.os.Bundle;
import android.content.Context;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
/** Run only under a separate test application ID. Never launches mining or the UI. */
public class ConfigDeviceTest extends Instrumentation {
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try { testPersistenceValidationAndPackagedEngine(); result.putString("stream", "PASS Android persistence, native engine dry run and service status lifecycle\n"); finish(-1,result); }
        catch (Throwable failure) { result.putString("stream", "FAIL " + failure.toString() + "\n"); finish(0,result); }
    }
    private static void fail(String message) { throw new AssertionError(message); }
    private static void assertTrue(boolean ok) { assertTrue("Assertion failed",ok); }
    private static void assertTrue(String message, boolean ok) { if(!ok) fail(message); }
    private static void assertEquals(Object a,Object b) { if(!a.equals(b)) fail("Expected " + a + ", got " + b); }
    private static void assertEquals(String message,int a,int b) { if(a!=b) fail(message + ": " + b); }
    public void testPersistenceValidationAndPackagedEngine() throws Exception {
        Context context=getTargetContext();
        assertEquals("io.xmrand.settingsqa",context.getPackageName());
        ConfigStore store=new ConfigStore(context);
        JSONObject c=MinerConfig.defaults();
        c.getJSONArray("pools").getJSONObject(0).put("url","pool.example:443").put("user","device-test-account");
        c.getJSONObject("cpu").put("rx/0",new JSONObject().put("threads",1).put("intensity",1).put("affinity",-1));
        c.getJSONObject("randomx").put("mode","light");c.put("retries",7);
        store.save(c);
        assertEquals(c.toString(),store.load().toString());
        c.getJSONObject("xmrand").put("resume-battery",1);
        try { store.save(c); fail("Invalid save accepted"); } catch(org.json.JSONException expected) {}
        assertEquals(40,store.load().getJSONObject("xmrand").getInt("resume-battery"));
        try(InputStream guide=context.getAssets().open("public-setup.html")) { assertTrue(guide.read()!=-1); }
        JSONObject runtime=MinerConfig.runtime(store.load());runtime.put("dry-run",true);
        File config=new File(context.getFilesDir(),"dry-run.json");
        try(FileOutputStream f=new FileOutputStream(config)){f.write(runtime.toString().getBytes(StandardCharsets.UTF_8));}
        Process process=new ProcessBuilder(new File(context.getApplicationInfo().nativeLibraryDir,"libxmrig.so").getPath(),"--config",config.getPath(),"--dry-run")
            .redirectErrorStream(true).start();
        try {
            assertTrue("Engine dry run timed out",process.waitFor(30,TimeUnit.SECONDS));
            assertEquals("Packaged engine rejected generated runtime",0,process.exitValue());
            ByteArrayOutputStream out=new ByteArrayOutputStream();
            byte[] buffer=new byte[4096]; int n;
            try(InputStream in=process.getInputStream()){while((n=in.read(buffer))!=-1)out.write(buffer,0,n);}
            String log=new String(out.toByteArray(),StandardCharsets.UTF_8);
            assertTrue("Engine did not report valid configuration",log.contains("OK"));
        } finally { if(process.isAlive()) process.destroyForcibly(); }
        JSONObject dry=store.load(); dry.put("dry-run",true); store.save(dry);
        android.content.Intent service=new android.content.Intent(context,MinerService.class);
        try {
            context.startForegroundService(new android.content.Intent(service).setAction(MinerService.ACTION_START));
            Thread.sleep(1000);
            context.startService(new android.content.Intent(service).setAction(MinerService.ACTION_STATUS));
            Thread.sleep(500);
            android.app.ActivityManager manager=(android.app.ActivityManager)context.getSystemService(Context.ACTIVITY_SERVICE);
            boolean requested=false;
            for(android.app.ActivityManager.RunningServiceInfo info:manager.getRunningServices(50))
                if(info.service.getClassName().equals(MinerService.class.getName())) requested=true;
            assertTrue("Status query cancelled requested mining while no process was running",requested);
        } finally {
            context.startService(new android.content.Intent(service).setAction(MinerService.ACTION_STOP));
        }

    }
}
