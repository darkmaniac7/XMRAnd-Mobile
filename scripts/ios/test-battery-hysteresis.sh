#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/test.cpp" <<'CPP'
#include <cassert>

#include "ios-app/BatteryHysteresis.h"

using xmrand_ios::BatteryGuardAction;
using xmrand_ios::batteryAllowsStart;
using xmrand_ios::batteryGuardAction;

int main()
{
    assert(batteryGuardAction(-1, false) == BatteryGuardAction::None);
    assert(batteryGuardAction(11, false) == BatteryGuardAction::None);
    assert(batteryGuardAction(10, false) == BatteryGuardAction::Pause);
    assert(batteryGuardAction(0, false) == BatteryGuardAction::Pause);
    assert(batteryGuardAction(79, true) == BatteryGuardAction::None);
    assert(batteryGuardAction(80, true) == BatteryGuardAction::Resume);
    assert(batteryGuardAction(100, true) == BatteryGuardAction::Resume);
    assert(batteryGuardAction(101, true) == BatteryGuardAction::None);
    assert(batteryGuardAction(15, false, 15, 40) == BatteryGuardAction::Pause);
    assert(batteryGuardAction(39, true, 15, 40) == BatteryGuardAction::None);
    assert(batteryGuardAction(40, true, 15, 40) == BatteryGuardAction::Resume);
    assert(!batteryAllowsStart(-1, false));
    assert(!batteryAllowsStart(101, false));
    assert(!batteryAllowsStart(10, false));
    assert(!batteryAllowsStart(10, true));
    assert(batteryAllowsStart(11, false));
    assert(batteryAllowsStart(80, false));
}
CPP

"${CXX:-c++}" -std=c++11 -Wall -Wextra -Werror -I"$repo" "$tmp/test.cpp" -o "$tmp/test"
"$tmp/test"
printf 'battery hysteresis test: PASS\n'
