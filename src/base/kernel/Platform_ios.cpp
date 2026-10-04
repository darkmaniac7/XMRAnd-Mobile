/* XMRig
 * Copyright (c) 2018-2025 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2025 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program. If not, see <http://www.gnu.org/licenses/>.
 */


#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pthread/qos.h>
#include <sys/resource.h>
#include <uv.h>


#include "base/kernel/Platform.h"
#include "version.h"


char *xmrig::Platform::createUserAgent()
{
    constexpr const size_t max = 256;

    char *buf = new char[max]();
    int length = snprintf(buf, max,
                          "%s/%s (iOS"
#                         ifdef XMRIG_ARM
                          "; arm64"
#                         endif
                          ") libuv/%s", APP_NAME, APP_VERSION, uv_version_string());

#   ifdef __clang__
    length += snprintf(buf + length, max - length, " clang/%d.%d.%d", __clang_major__, __clang_minor__, __clang_patchlevel__);
#   elif defined(__GNUC__)
    length += snprintf(buf + length, max - length, " gcc/%d.%d.%d", __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
#   endif

    return buf;
}


bool xmrig::Platform::setThreadAffinity(uint64_t)
{
    return false;
}


void xmrig::Platform::setProcessPriority(int)
{
}


void xmrig::Platform::setThreadPriority(int priority)
{
    // Apple Silicon ignores THREAD_AFFINITY_POLICY (see setThreadAffinity above),
    // so worker threads cannot be pinned to P-cores. The only real scheduling lever
    // is the Darwin QoS class. This is opt-in via XMRAND_IOS_QOS so the proven
    // default (plain nice, empirically tuned) is unchanged unless benchmarked:
    //   XMRAND_IOS_QOS=1|initiated -> QOS_CLASS_USER_INITIATED (P-core biased)
    //   XMRAND_IOS_QOS=interactive -> QOS_CLASS_USER_INTERACTIVE
    //   XMRAND_IOS_QOS=0|unset     -> no QoS override
    if (const char *qos = getenv("XMRAND_IOS_QOS")) {
        if (strcmp(qos, "0") != 0) {
            qos_class_t cls = (strcmp(qos, "interactive") == 0) ? QOS_CLASS_USER_INTERACTIVE
                                                                : QOS_CLASS_USER_INITIATED;
            pthread_set_qos_class_self_np(cls, 0);
        }
    }

    if (priority == -1) {
        return;
    }

    int prio = 19;
    switch (priority)
    {
    case 1:
        prio = 5;
        break;

    case 2:
        prio = 0;
        break;

    case 3:
        prio = -5;
        break;

    case 4:
        prio = -10;
        break;

    case 5:
        prio = -15;
        break;

    default:
        break;
    }

    setpriority(PRIO_PROCESS, 0, prio);
}


bool xmrig::Platform::isOnBatteryPower()
{
    return false;
}


uint64_t xmrig::Platform::idleTime()
{
    return 0;
}
