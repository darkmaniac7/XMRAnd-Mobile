#ifndef XMRAND_IOS_BATTERY_HYSTERESIS_H
#define XMRAND_IOS_BATTERY_HYSTERESIS_H

namespace xmrand_ios {

constexpr int kBatteryPausePercent = 10;
constexpr int kBatteryResumePercent = 80;

enum class BatteryGuardAction
{
    None,
    Pause,
    Resume
};

constexpr BatteryGuardAction batteryGuardAction(int percent, bool paused, int pause = kBatteryPausePercent, int resume = kBatteryResumePercent)
{
    return percent < 0 || percent > 100
        ? BatteryGuardAction::None
        : (!paused && percent <= pause
            ? BatteryGuardAction::Pause
            : (paused && percent >= resume
                ? BatteryGuardAction::Resume
                : BatteryGuardAction::None));
}

constexpr bool batteryAllowsStart(int percent, bool paused)
{
    return percent > kBatteryPausePercent && percent <= 100 && !paused;
}

} // namespace xmrand_ios

#endif // XMRAND_IOS_BATTERY_HYSTERESIS_H
