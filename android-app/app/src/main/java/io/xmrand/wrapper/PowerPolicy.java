package io.xmrand.wrapper;

/** Stateful hysteresis prevents repeated start/stop at a threshold. */
public final class PowerPolicy {
    private boolean lowBattery, hot;
    public String update(int percent, int temperatureDecic, boolean charging,
                         boolean chargingOnly, int pause, int resume, int maxTemperature) {
        if (percent < 0 || percent > 100) return "Waiting for a battery reading";
        if (percent <= pause) lowBattery = true;
        else if (percent >= resume) lowBattery = false;
        if (temperatureDecic >= maxTemperature * 10) hot = true;
        else if (temperatureDecic > 0 && temperatureDecic <= (maxTemperature - 3) * 10) hot = false;
        if (hot) return "Paused for battery temperature";
        if (lowBattery) return "Paused for battery; resumes at " + resume + "%";
        if (chargingOnly && !charging) return "Waiting for charger";
        return "";
    }
}
