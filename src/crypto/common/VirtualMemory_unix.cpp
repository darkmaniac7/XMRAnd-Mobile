/* XMRig
 * Copyright (c) 2018-2020 tevador     <tevador@gmail.com>
 * Copyright (c) 2018-2023 SChernykh   <https://github.com/SChernykh>
 * Copyright (c) 2016-2023 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
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

#include "crypto/common/VirtualMemory.h"
#include "backend/cpu/Cpu.h"
#include "crypto/common/portable/mm_malloc.h"


#include <cmath>
#include <cstdlib>
#include <fstream>
#include <sys/mman.h>
#include <unistd.h>


#ifdef XMRIG_OS_APPLE
#   include <libkern/OSCacheControl.h>
#   include <mach/vm_statistics.h>
#   include <pthread.h>
#   include <TargetConditionals.h>
#   if defined(XMRIG_ARM) && (!defined(XMRIG_OS_IOS) || defined(XMRIG_IOS_JIT))
#       define MEXTRA MAP_JIT
#       if !defined(XMRIG_OS_IOS)
#           define XMRIG_APPLE_JIT_WRITE_PROTECT
#       endif
#   else
#       define MEXTRA 0
#   endif
#else
#   define MEXTRA 0
#endif


#ifdef XMRIG_OS_LINUX
#   include "crypto/common/LinuxMemory.h"
#endif


#ifndef MAP_HUGE_SHIFT
#   define MAP_HUGE_SHIFT 26
#endif


#ifndef MAP_HUGE_MASK
#   define MAP_HUGE_MASK 0x3f
#endif

#ifdef XMRIG_OS_FREEBSD
#   ifndef MAP_ALIGNED_SUPER
#       define MAP_ALIGNED_SUPER 0
#   endif
#   ifndef MAP_PREFAULT_READ
#       define MAP_PREFAULT_READ 0
#   endif
#endif


#ifdef XMRIG_SECURE_JIT
#   define SECURE_PROT_EXEC 0
#else
#   define SECURE_PROT_EXEC PROT_EXEC
#endif


#ifndef MADV_COLLAPSE
#   define MADV_COLLAPSE 25
#endif


#if defined(XMRIG_OS_IOS) && defined(XMRIG_IOS_JIT)
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <atomic>
#include <mutex>
#include <unordered_map>

// <mach/mach_vm.h> is #error-unsupported on iOS; declare the one call we need.
extern "C" kern_return_t mach_vm_remap(mach_port_t, uint64_t *, uint64_t, uint64_t,
    int, mach_port_t, uint64_t, int, vm_prot_t *, vm_prot_t *, unsigned int);
#ifndef VM_FLAGS_ANYWHERE
#   define VM_FLAGS_ANYWHERE 0x0001
#endif
#ifndef VM_INHERIT_NONE
#   define VM_INHERIT_NONE 2
#endif
extern "C" int csops(pid_t, unsigned int, void *, size_t);
#ifndef CS_OPS_STATUS
#   define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#   define CS_DEBUGGED 0x10000000
#endif

namespace {

size_t iosPageSize()
{
    const long pageSize = sysconf(_SC_PAGESIZE);

    return pageSize > 0 ? static_cast<size_t>(pageSize) : 16384U;
}


size_t iosPageAlign(size_t size)
{
    const size_t pageSize = iosPageSize();

    return ((size + pageSize - 1U) / pageSize) * pageSize;
}


// iOS 26 / arm64e TXM refuses to let an app create its own executable memory even
// under CS_DEBUGGED; a debugger must allocate it. Use the debugger-cooperative
// dual-map path on iOS >= 26, and keep the self-JIT mprotect path on iOS <= 18.
bool iosNeedsDualMap()
{
    static std::atomic<int> cached{-1};
    int c = cached.load(std::memory_order_relaxed);
    if (c >= 0) {
        return c != 0;
    }
    char buf[64] = {0};
    size_t len   = sizeof(buf);
    int major    = 0;
    if (sysctlbyname("kern.osproductversion", buf, &len, nullptr, 0) == 0) {
        major = atoi(buf);
    }
    c = (major >= 26) ? 1 : 0;
    cached.store(c, std::memory_order_relaxed);
    return c != 0;
}


bool iosDebuggerAttached()
{
    uint32_t flags = 0;
    csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
}


// Debugger-cooperative R+X allocation via StikDebug's universal JIT-call ABI:
// x0=0 (allocate), x1=size, x16=1 (prepare region), brk #0xf00d. Both StikDebug
// and our gdb-remote allocator allocate R+X (_M,rx), return the address in x0,
// and step past the BRK. Serialized so concurrent mining-thread requests never
// race on the single shared debugger channel.
std::mutex g_brkMtx;
void *iosDbgAllocRX(size_t size)
{
    if (!iosDebuggerAttached()) {
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(g_brkMtx);
    register uint64_t x0 __asm__("x0") = 0;
    register uint64_t x1 __asm__("x1") = static_cast<uint64_t>(size);
    register uint64_t x16 __asm__("x16") = 1;
    __asm__ __volatile__("brk #0xf00d" : "+r"(x0), "+r"(x1), "+r"(x16) : : "memory", "cc");
    return reinterpret_cast<void *>(x0);
}


// RW (write) alias -> RX (execute) alias, populated at dual-map alloc time and
// consulted once per JitCompiler by VirtualMemory::executableAlias().
std::mutex g_aliasMtx;
std::unordered_map<void *, void *> g_alias;   // rw -> rx
std::atomic<bool> g_anyDualMaps{false};

} // namespace
#endif


#if defined(XMRIG_OS_LINUX) || (!defined(XMRIG_OS_APPLE) && !defined(XMRIG_OS_FREEBSD))
static inline int hugePagesFlag(size_t size)
{
    return (static_cast<int>(log2(size)) & MAP_HUGE_MASK) << MAP_HUGE_SHIFT;
}
#endif


bool xmrig::VirtualMemory::isHugepagesAvailable()
{
#   ifdef XMRIG_OS_LINUX
    return std::ifstream("/proc/sys/vm/nr_hugepages").good() || std::ifstream("/sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages").good();
#   elif defined(XMRIG_OS_MACOS) && defined(XMRIG_ARM) || defined(XMRIG_OS_HAIKU)
    return false;
#   else
    return true;
#   endif
}


bool xmrig::VirtualMemory::isOneGbPagesAvailable()
{
#   ifdef XMRIG_OS_LINUX
    return Cpu::info()->hasOneGbPages();
#   else
    return false;
#   endif
}


bool xmrig::VirtualMemory::protectRW(void *p, size_t size)
{
#   ifdef XMRIG_APPLE_JIT_WRITE_PROTECT
    pthread_jit_write_protect_np(false);
    return true;
#   else
    return mprotect(p, size, PROT_READ | PROT_WRITE) == 0;
#   endif
}


bool xmrig::VirtualMemory::protectRWX(void *p, size_t size)
{
    return mprotect(p, size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0;
}


bool xmrig::VirtualMemory::protectRX(void *p, size_t size)
{
    bool result = true;

#   ifdef XMRIG_APPLE_JIT_WRITE_PROTECT
    pthread_jit_write_protect_np(true);
#   else
    result = (mprotect(p, size, PROT_READ | PROT_EXEC) == 0);
#   endif

#   if defined(XMRIG_ARM)
    flushInstructionCache(p, size);
#   endif

    return result;
}


void *xmrig::VirtualMemory::allocateExecutableMemory(size_t size, bool hugePages)
{
#   if defined(XMRIG_OS_IOS) && defined(XMRIG_IOS_JIT)
    const size_t iosSize = iosPageAlign(size);
    void *mem = MAP_FAILED;
    if (iosNeedsDualMap()) {
        // iOS 26 / arm64e TXM: the app cannot make its own executable memory, so
        // the attached debugger allocates an R+X region and we dual-map it as a
        // writable alias (vm_remap, same physical pages). The JIT emits into the RW
        // alias; execution goes through the RX alias (VirtualMemory::executableAlias).
        void *rx = iosDbgAllocRX(iosSize);
        if (rx == nullptr) {
            return nullptr;   // hard fail — no silent fallback to a path that faults on iOS 26
        }
        uint64_t rw = 0;
        vm_prot_t cur = 0, max = 0;
        kern_return_t kr = mach_vm_remap(mach_task_self(), &rw, iosSize, 0, VM_FLAGS_ANYWHERE,
                                         mach_task_self(), (uint64_t)(uintptr_t)rx, 0, &cur, &max, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            return nullptr;
        }
        if (mprotect(reinterpret_cast<void *>(rw), iosSize, PROT_READ | PROT_WRITE) != 0) {
            munmap(reinterpret_cast<void *>(rw), iosSize);
            return nullptr;
        }
        {
            std::lock_guard<std::mutex> lock(g_aliasMtx);
            g_alias[reinterpret_cast<void *>(rw)] = rx;
            g_anyDualMaps.store(true, std::memory_order_relaxed);
        }
        return reinterpret_cast<void *>(rw);
    }
    // iOS <= 18: self-JIT under CS_DEBUGGED via a W^X mprotect toggle. Allocate
    // writable-only; protectRW()/protectRX() flip R/W <-> R/X. Probe the exec
    // transition once to confirm CS_DEBUGGED is active.
    mem = mmap(0, iosSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mem != MAP_FAILED) {
        if (mprotect(mem, iosSize, PROT_READ | PROT_EXEC) != 0) {
            munmap(mem, iosSize);
            mem = MAP_FAILED;
        }
        else {
            mprotect(mem, iosSize, PROT_READ | PROT_WRITE);
        }
    }
#   elif defined(XMRIG_OS_APPLE)
    void *mem = mmap(0, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MEXTRA, -1, 0);
#   ifdef XMRIG_APPLE_JIT_WRITE_PROTECT
    pthread_jit_write_protect_np(false);
#   endif
#   elif defined(XMRIG_OS_FREEBSD)
    void *mem = nullptr;

    if (hugePages) {
        mem = mmap(0, size, PROT_READ | PROT_WRITE | SECURE_PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_ALIGNED_SUPER | MAP_PREFAULT_READ, -1, 0);
    }

    if (!mem) {
        mem = mmap(0, size, PROT_READ | PROT_WRITE | SECURE_PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    }
#   elif defined(XMRIG_OS_HAIKU)
    void *mem = mmap(0, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
#   else

    void *mem = nullptr;

    if (hugePages) {
        mem = mmap(0, align(size), PROT_READ | PROT_WRITE | SECURE_PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE | hugePagesFlag(hugePageSize()), -1, 0);
    }

    if (!mem) {
        mem = mmap(0, size, PROT_READ | PROT_WRITE | SECURE_PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    }

#   endif

    return mem == MAP_FAILED ? nullptr : mem;
}


bool xmrig::VirtualMemory::isJITAvailable()
{
#   if defined(XMRIG_OS_IOS) && defined(XMRIG_IOS_JIT)
    if (iosDebuggerAttached()) {
        return true;
    }

    // TrollStore/jailbreak packages are explicitly distinguished at build time.
    // A sandboxed UIKit process cannot reliably probe /var/jb even when the
    // executable is trusted for self-JIT. Stock builds always require a debugger.
#   if defined(XMRIG_IOS_TROLLSTORE_JIT)
    return !iosNeedsDualMap();
#   else
    return false;
#   endif
#   else
    return true;
#   endif
}


void *xmrig::VirtualMemory::allocateLargePagesMemory(size_t size)
{
#   if defined(XMRIG_OS_APPLE)
    void *mem = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, VM_FLAGS_SUPERPAGE_SIZE_2MB, 0);
#   elif defined(XMRIG_OS_FREEBSD)
    void *mem = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_ALIGNED_SUPER | MAP_PREFAULT_READ, -1, 0);
#   elif defined(XMRIG_OS_HAIKU)
    void *mem = nullptr;
#   else
    void *mem = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE | hugePagesFlag(hugePageSize()), 0, 0);
#   endif

    return mem == MAP_FAILED ? nullptr : mem;
}


void *xmrig::VirtualMemory::allocateOneGbPagesMemory(size_t size)
{
#   ifdef XMRIG_OS_LINUX
    if (isOneGbPagesAvailable()) {
        void *mem = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE | hugePagesFlag(kOneGiB), 0, 0);

        return mem == MAP_FAILED ? nullptr : mem;
    }
#   endif

    return nullptr;
}


void xmrig::VirtualMemory::flushInstructionCache(void *p, size_t size)
{
#   if defined(XMRIG_OS_APPLE)
    sys_icache_invalidate(p, size);
#   elif defined (HAVE_BUILTIN_CLEAR_CACHE) || defined (__GNUC__)
    __builtin___clear_cache(reinterpret_cast<char*>(p), reinterpret_cast<char*>(p) + size);
#   endif
}


void *xmrig::VirtualMemory::executableAlias(void *rw)
{
#   if defined(XMRIG_OS_IOS) && defined(XMRIG_IOS_JIT)
    if (g_anyDualMaps.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(g_aliasMtx);
        auto it = g_alias.find(rw);
        if (it != g_alias.end()) {
            return it->second;
        }
    }
#   endif
    return rw;
}


void xmrig::VirtualMemory::freeLargePagesMemory(void *p, size_t size)
{
#   if defined(XMRIG_OS_IOS) && defined(XMRIG_IOS_JIT)
    if (g_anyDualMaps.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lock(g_aliasMtx);
        auto it = g_alias.find(p);
        if (it != g_alias.end()) {
            g_alias.erase(it);
            munmap(p, iosPageAlign(size));   // free the RW alias; the RX region is debugger-owned
            return;
        }
    }
#   endif
    munmap(p, size);
}


void xmrig::VirtualMemory::osInit(size_t hugePageSize)
{
    if (hugePageSize) {
        m_hugePageSize = hugePageSize;
    }
}


bool xmrig::VirtualMemory::allocateLargePagesMemory()
{
#   ifdef XMRIG_OS_LINUX
    LinuxMemory::reserve(m_size, m_node, hugePageSize());
#   endif

    m_scratchpad = static_cast<uint8_t*>(allocateLargePagesMemory(m_size));
    if (m_scratchpad) {
        m_flags.set(FLAG_HUGEPAGES, true);

        madvise(m_scratchpad, m_size, MADV_RANDOM | MADV_WILLNEED);

        if (mlock(m_scratchpad, m_size) == 0) {
            m_flags.set(FLAG_LOCK, true);
        }

        return true;
    }

    return false;
}


bool xmrig::VirtualMemory::allocateOneGbPagesMemory()
{
#   ifdef XMRIG_OS_LINUX
    LinuxMemory::reserve(m_size, m_node, kOneGiB);
#   endif

    m_scratchpad = static_cast<uint8_t*>(allocateOneGbPagesMemory(m_size));
    if (m_scratchpad) {
        m_flags.set(FLAG_1GB_PAGES, true);

        madvise(m_scratchpad, m_size, MADV_RANDOM | MADV_WILLNEED);

        if (mlock(m_scratchpad, m_size) == 0) {
            m_flags.set(FLAG_LOCK, true);
        }

        return true;
    }

    return false;
}


bool xmrig::VirtualMemory::adviseLargePages(void *p, size_t size)
{
#   if defined(XMRIG_OS_ANDROID) || defined(XMRIG_OS_LINUX)
    // MADV_COLLAPSE works even if /sys/kernel/mm/transparent_hugepage/enabled is set to "never", but only on Linux 6.1+
    return (madvise(p, size, MADV_COLLAPSE) == 0) || (madvise(p, size, MADV_HUGEPAGE) == 0);
#   else
    return false;
#   endif
}


void xmrig::VirtualMemory::freeLargePagesMemory()
{
    if (m_flags.test(FLAG_LOCK)) {
        munlock(m_scratchpad, m_size);
    }

    freeLargePagesMemory(m_scratchpad, m_size);
}
