package io.xmrand.wrapper;
import org.junit.Test;
import static org.junit.Assert.*;
public class PowerPolicyTest {
    @Test public void batteryAndTemperatureHaveIndependentHysteresis() {
        PowerPolicy p=new PowerPolicy();
        assertEquals("",p.update(80,300,false,false,15,40,45));
        assertTrue(p.update(15,300,false,false,15,40,45).contains("battery"));
        assertFalse(p.update(39,300,true,false,15,40,45).isEmpty());
        assertEquals("",p.update(40,300,true,false,15,40,45));
        assertTrue(p.update(80,450,true,false,15,40,45).contains("temperature"));
        assertFalse(p.update(80,430,true,false,15,40,45).isEmpty());
        assertEquals("",p.update(80,420,true,false,15,40,45));
    }
    @Test public void chargingAndUnknownReadingsGateStart() {
        PowerPolicy p=new PowerPolicy();
        assertFalse(p.update(-1,300,true,false,15,40,45).isEmpty());
        assertEquals("Waiting for charger",p.update(80,300,false,true,15,40,45));
        assertEquals("",p.update(80,300,true,true,15,40,45));
    }
}
