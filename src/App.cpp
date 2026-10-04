/* XMRig
 * Copyright 2010      Jeff Garzik <jgarzik@pobox.com>
 * Copyright 2012-2014 pooler      <pooler@litecoinpool.org>
 * Copyright 2014      Lucas Jones <https://github.com/lucasjones>
 * Copyright 2014-2016 Wolf9466    <https://github.com/OhGodAPet>
 * Copyright 2016      Jay D Dee   <jayddee246@gmail.com>
 * Copyright 2017-2018 XMR-Stak    <https://github.com/fireice-uk>, <https://github.com/psychocrypt>
 * Copyright 2018      Lee Clagett <https://github.com/vtnerd>
 * Copyright 2018-2024 SChernykh   <https://github.com/SChernykh>
 * Copyright 2016-2024 XMRig       <https://github.com/xmrig>, <support@xmrig.com>
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

#include <cstdlib>
#include <mutex>
#include <uv.h>


#include "App.h"
#include "backend/cpu/Cpu.h"
#include "base/io/Console.h"
#include "base/io/log/Log.h"
#include "base/io/log/Tags.h"
#include "base/io/Signals.h"
#include "base/kernel/Platform.h"
#include "core/config/Config.h"
#include "core/Controller.h"
#include "Summary.h"
#include "version.h"


#if defined(XMRIG_OS_IOS)
namespace {

std::mutex g_externalMiningControlMutex;
bool g_externalMiningEnabled = true;
xmrig::App *g_externalMiningApp = nullptr;

} // namespace
#endif


xmrig::App::App(Process *process)
{
    m_controller = std::make_shared<Controller>(process);
}


xmrig::App::~App()
{
    Cpu::release();
}


#if defined(XMRIG_OS_IOS)
void xmrig::App::setMiningEnabled(bool enabled)
{
    std::lock_guard<std::mutex> lock(g_externalMiningControlMutex);
    g_externalMiningEnabled = enabled;

    if (g_externalMiningApp && g_externalMiningApp->m_externalMiningControl) {
        uv_async_send(g_externalMiningApp->m_externalMiningControl);
    }
}


bool xmrig::App::initExternalMiningControl()
{
    auto *control = new uv_async_t;
    if (uv_async_init(uv_default_loop(), control, App::onExternalMiningControl) != 0) {
        delete control;
        return false;
    }

    control->data = this;
    bool enabled = true;
    {
        std::lock_guard<std::mutex> lock(g_externalMiningControlMutex);
        m_externalMiningControl = control;
        g_externalMiningApp = this;
        enabled = g_externalMiningEnabled;
    }

    m_controller->execCommand(enabled ? 'r' : 'p');
    return true;
}


void xmrig::App::closeExternalMiningControl()
{
    uv_async_t *control = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_externalMiningControlMutex);
        if (g_externalMiningApp == this) {
            g_externalMiningApp = nullptr;
        }
        control = m_externalMiningControl;
        m_externalMiningControl = nullptr;
    }

    if (control) {
        uv_close(reinterpret_cast<uv_handle_t *>(control), [](uv_handle_t *handle) {
            delete reinterpret_cast<uv_async_t *>(handle);
        });
    }
}


void xmrig::App::onExternalMiningControl(uv_async_t *handle)
{
    auto *app = static_cast<App *>(handle->data);
    bool enabled = true;
    {
        std::lock_guard<std::mutex> lock(g_externalMiningControlMutex);
        if (g_externalMiningApp != app) {
            return;
        }
        enabled = g_externalMiningEnabled;
    }

    app->m_controller->execCommand(enabled ? 'r' : 'p');
}
#endif


int xmrig::App::exec()
{
    if (!m_controller->isReady()) {
        LOG_EMERG("no valid configuration found, try https://xmrig.com/wizard");

        return 2;
    }

    int rc = 0;
    if (background(rc)) {
        return rc;
    }

    m_signals = std::make_shared<Signals>(this);

    rc = m_controller->init();
    if (rc != 0) {
        return rc;
    }

#   ifndef XMRIG_OS_IOS
    if (!m_controller->isBackground()) {
        m_console = std::make_shared<Console>(this);
    }
#   endif

    Summary::print(m_controller.get());

    if (m_controller->config()->isDryRun()) {
        LOG_NOTICE("%s " WHITE_BOLD("OK"), Tags::config());

        return 0;
    }

    m_controller->start();

#   if defined(XMRIG_OS_IOS)
    if (!initExternalMiningControl()) {
        LOG_ERR("%s " RED_BOLD("battery control initialization failed; refusing to mine"), Tags::miner());
        close();
        uv_run(uv_default_loop(), UV_RUN_DEFAULT);
        uv_loop_close(uv_default_loop());
        return 4;
    }
#   endif

    rc = uv_run(uv_default_loop(), UV_RUN_DEFAULT);
    uv_loop_close(uv_default_loop());

    return rc;
}


void xmrig::App::onConsoleCommand(char command)
{
    if (command == 3) {
        LOG_WARN("%s " YELLOW("Ctrl+C received, exiting"), Tags::signal());
        close();
    }
    else {
        m_controller->execCommand(command);
    }
}


void xmrig::App::onSignal(int signum)
{
    switch (signum)
    {
    case SIGHUP:
    case SIGTERM:
    case SIGINT:
        return close();

    default:
        break;
    }
}


void xmrig::App::close()
{
#   if defined(XMRIG_OS_IOS)
    closeExternalMiningControl();
#   endif

    m_signals.reset();
    m_console.reset();

    m_controller->stop();

    Log::destroy();
}
