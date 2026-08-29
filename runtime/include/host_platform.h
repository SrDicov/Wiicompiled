#pragma once

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

// The runtime always targets Windows, but here we detect if we're running
// under Wine/Proton on Linux. Here we can edit certain features (such as
// removing exclusive fullscreen)
namespace RuntimeHostPlatform {

// True when running under Wine/Proton, detected
// via Wine's ntdll.dll exports wine_get_version
inline bool IsRunningUnderWine() noexcept {
#ifdef _WIN32
    static const bool result = [] {
        const HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
        if (ntdll == nullptr) {
            return false;
        }
        return ::GetProcAddress(ntdll, "wine_get_version") != nullptr;
    }();
    return result;
#else
    return false;
#endif
}

} // namespace RuntimeHostPlatform
