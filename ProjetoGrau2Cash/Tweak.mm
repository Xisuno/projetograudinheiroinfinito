// Projeto Grau 2 - infinite money (AtlasEconomia.Carteira), IL2CPP, iOS jailbreak tweak.
// Hooks code only; it never writes the protected wallet memory (IntBlindado/Lacre/Cofre stay consistent).
#import <Foundation/Foundation.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <string>
#include <thread>
#include <unistd.h>

#include <substrate.h>

#include "Config.h"
#include "Logic.h"

#define LOG(fmt, ...) NSLog(@"[ProjetoGrau2Cash] " fmt, ##__VA_ARGS__)

namespace {

// ---------- hooks (IL2CPP static methods: trailing const MethodInfo* argument) ----------

int32_t (*orig_get_s_Centavos)(const void*) = nullptr;
int32_t hook_get_s_Centavos(const void* mi) {
    return logic::ApplyBalanceFloor(orig_get_s_Centavos(mi), cfg::kBalanceFloorCentavos);
}

uint8_t hook_Tem(int32_t /*centavos*/, const void* /*mi*/) { return 1; }

uint8_t hook_Debitar(int32_t /*centavos*/, void* /*rotulo*/, int32_t /*tipo*/, const void* /*mi*/) { return 1; }

// ---------- module / pointer helpers ----------

struct ModuleInfo {
    std::string path;
    intptr_t    slide    = 0;
    uintptr_t   textBase = 0;
    uintptr_t   textSize = 0;
};

uintptr_t StripPac(uintptr_t p) {
#if __has_feature(ptrauth_calls)
    return reinterpret_cast<uintptr_t>(ptrauth_strip(reinterpret_cast<void*>(p), ptrauth_key_function_pointer));
#else
    return p;
#endif
}

bool InText(const ModuleInfo& m, uintptr_t a) {
    return a >= m.textBase && a < m.textBase + m.textSize && (a & 3) == 0;
}

bool FindModule(const char* name, ModuleInfo& out) {
    const uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
        const char* p = _dyld_get_image_name(i);
        if (!p) continue;
        const char* base = std::strrchr(p, '/');
        base = base ? base + 1 : p;
        if (std::strcmp(base, name) != 0) continue;

        auto* h = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if (!h || h->magic != MH_MAGIC_64) continue;
        unsigned long size = 0;
        uint8_t* text = getsegmentdata(h, "__TEXT", &size);
        if (!text || size == 0) continue;

        out.path     = p;
        out.slide    = _dyld_get_image_vmaddr_slide(i);
        out.textBase = reinterpret_cast<uintptr_t>(text);
        out.textSize = size;
        return true;
    }
    return false;
}

// ---------- il2cpp API (resolved by name from the module's exports) ----------

struct Il2cppApi {
    void*        (*domain_get)()                                              = nullptr;
    void**       (*domain_get_assemblies)(void*, size_t*)                     = nullptr;
    void*        (*assembly_get_image)(void*)                                 = nullptr;
    const char*  (*image_get_name)(void*)                                     = nullptr;
    void*        (*class_from_name)(void*, const char*, const char*)          = nullptr;
    const void*  (*class_get_method_from_name)(void*, const char*, int)       = nullptr;
    void*        (*thread_attach)(void*)                                      = nullptr;
    void         (*thread_detach)(void*)                                      = nullptr;

    bool Load(const std::string& modulePath) {
        void* h = dlopen(modulePath.c_str(), RTLD_NOLOAD | RTLD_LAZY);
        if (!h) return false;
        auto sym = [&](const char* nm, auto& dst) {
            dst = reinterpret_cast<std::remove_reference_t<decltype(dst)>>(dlsym(h, nm));
            return dst != nullptr;
        };
        const bool ok = sym("il2cpp_domain_get", domain_get)
                     && sym("il2cpp_domain_get_assemblies", domain_get_assemblies)
                     && sym("il2cpp_assembly_get_image", assembly_get_image)
                     && sym("il2cpp_image_get_name", image_get_name)
                     && sym("il2cpp_class_from_name", class_from_name)
                     && sym("il2cpp_class_get_method_from_name", class_get_method_from_name)
                     && sym("il2cpp_thread_attach", thread_attach)
                     && sym("il2cpp_thread_detach", thread_detach);
        dlclose(h);
        return ok;
    }

    // MethodInfo's first field is methodPointer. Returns the PAC-stripped native address or 0.
    uintptr_t ResolveMethod(void* domain, const char* ns, const char* cls, const char* method, int argc) const {
        size_t count = 0;
        void** assemblies = domain_get_assemblies(domain, &count);
        if (!assemblies || count == 0 || count > 4096) return 0;
        for (size_t i = 0; i < count; ++i) {
            void* image = assembly_get_image(assemblies[i]);
            const char* nm = image ? image_get_name(image) : nullptr;
            if (!nm || std::strcmp(nm, cfg::kGameImageName) != 0) continue;
            void* klass = class_from_name(image, ns, cls);
            if (!klass) return 0;
            const void* mi = class_get_method_from_name(klass, method, argc);
            if (!mi) return 0;
            return StripPac(*reinterpret_cast<const uintptr_t*>(mi));
        }
        return 0;
    }
};

// ---------- install ----------

struct Target {
    const char* method;
    int         argc;
    uint64_t    dumpVa;
    void*       hook;
    void**      orig; // may be null when the original is never called
};

const Target kTargets[] = {
    {"get_s_Centavos", 0, cfg::kVaGetSCentavos, reinterpret_cast<void*>(&hook_get_s_Centavos), reinterpret_cast<void**>(&orig_get_s_Centavos)},
    {"Tem",            1, cfg::kVaTem,          reinterpret_cast<void*>(&hook_Tem),            nullptr},
    {"Debitar",        3, cfg::kVaDebitar,      reinterpret_cast<void*>(&hook_Debitar),        nullptr},
};
constexpr size_t kTargetCount = sizeof(kTargets) / sizeof(kTargets[0]);

// All addresses are resolved and validated first; nothing is patched unless every one is valid.
bool Install(const ModuleInfo& m, const Il2cppApi* api, void* domain) {
    uintptr_t addr[kTargetCount] = {};
    for (size_t i = 0; i < kTargetCount; ++i) {
        const Target& t = kTargets[i];
        const uintptr_t viaDump = static_cast<uintptr_t>(m.slide) + static_cast<uintptr_t>(t.dumpVa);
        uintptr_t viaApi = 0;
        if (api && domain) viaApi = api->ResolveMethod(domain, cfg::kNamespace, cfg::kClass, t.method, t.argc);

        if (viaApi) {
            if (!InText(m, viaApi)) { LOG(@"%s: il2cpp address 0x%lx outside __TEXT, rejected", t.method, (unsigned long)viaApi); return false; }
            if (viaApi != viaDump) LOG(@"%s: il2cpp address 0x%lx differs from dump VA 0x%lx - game build differs from dump, using il2cpp address", t.method, (unsigned long)viaApi, (unsigned long)viaDump);
            addr[i] = viaApi;
        } else if (!api) {
            if (!InText(m, viaDump)) { LOG(@"%s: dump VA 0x%lx outside __TEXT, rejected", t.method, (unsigned long)viaDump); return false; }
            LOG(@"%s: il2cpp API unavailable, using UNVERIFIED dump VA 0x%lx", t.method, (unsigned long)viaDump);
            addr[i] = viaDump;
        } else {
            return false; // API present but method not found yet: caller retries
        }
    }
    for (size_t i = 0; i < kTargetCount; ++i)
        MSHookFunction(reinterpret_cast<void*>(addr[i]), kTargets[i].hook, kTargets[i].orig);
    for (size_t i = 0; i < kTargetCount; ++i) LOG(@"hooked %s at 0x%lx", kTargets[i].method, (unsigned long)addr[i]);
    return true;
}

void Worker() {
    for (int attempt = 0; attempt < cfg::kPollMaxTries; ++attempt) {
        ModuleInfo m;
        if (FindModule(cfg::kUnityModuleName, m)) {
            Il2cppApi api;
            if (!api.Load(m.path)) {
                LOG(@"il2cpp exports not found in %s", m.path.c_str());
                if (Install(m, nullptr, nullptr)) return;
                return; // VA path failed validation; nothing else to try
            }
            if (void* domain = api.domain_get()) {
                void* thread = api.thread_attach(domain);
                const bool ok = Install(m, &api, domain);
                if (thread) api.thread_detach(thread);
                if (ok) return;
            }
        }
        usleep(cfg::kPollIntervalMs * 1000);
    }
    LOG(@"gave up: %s or Carteira methods never became available", cfg::kUnityModuleName);
}

} // namespace

__attribute__((constructor)) static void TweakInit() {
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
    std::thread(Worker).detach();
}
