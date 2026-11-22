// Projeto Grau 2 - infinite money (AtlasEconomia.Carteira), IL2CPP, iOS jailbreak tweak.
// Hooks code only; it never writes the protected wallet memory (IntBlindado/Lacre/Cofre stay consistent).
// Log: NSLog (prefix [ProjetoGrau2Cash]) and <app sandbox>/Documents/ProjetoGrau2Cash.log
#import <Foundation/Foundation.h>

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#include <substrate.h>

#include "Config.h"
#include "Logic.h"

namespace {

// ---------- logging ----------

std::mutex gLogMutex;

FILE* OpenLogFile() {
    @autoreleasepool {
        NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count == 0) return nullptr;
        NSString* path = [dirs[0] stringByAppendingPathComponent:@"ProjetoGrau2Cash.log"];
        return fopen(path.fileSystemRepresentation, "a");
    }
}

void Logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void Logf(const char* fmt, ...) {
    char buf[600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    NSLog(@"[ProjetoGrau2Cash] %s", buf);
    std::lock_guard<std::mutex> g(gLogMutex);
    static FILE* f = OpenLogFile();
    if (f) { fprintf(f, "%s\n", buf); fflush(f); }
}

// ---------- hooks (IL2CPP static methods: trailing const MethodInfo* argument) ----------

enum HookId { kGetSCentavos, kGetCentavos, kGetReais, kTem, kDebitar, kHookCount };
const char* const kHookNames[kHookCount] = {"get_s_Centavos", "get_Centavos", "get_Reais", "Tem", "Debitar"};
std::atomic<uint32_t> gCalls[kHookCount];

void Seen(HookId id) {
    if (gCalls[id].fetch_add(1, std::memory_order_relaxed) == 0) Logf("first call of hook %s", kHookNames[id]);
}

int32_t (*orig_get_s_Centavos)(const void*) = nullptr;
int32_t hook_get_s_Centavos(const void* mi) {
    Seen(kGetSCentavos);
    return logic::ApplyBalanceFloor(orig_get_s_Centavos(mi), cfg::kBalanceFloorCentavos);
}

int32_t (*orig_get_Centavos)(const void*) = nullptr;
int32_t hook_get_Centavos(const void* mi) {
    Seen(kGetCentavos);
    return logic::ApplyBalanceFloor(orig_get_Centavos(mi), cfg::kBalanceFloorCentavos);
}

float (*orig_get_Reais)(const void*) = nullptr;
float hook_get_Reais(const void* mi) {
    Seen(kGetReais);
    return logic::ApplyReaisFloor(orig_get_Reais(mi), cfg::kBalanceFloorCentavos);
}

uint8_t hook_Tem(int32_t /*centavos*/, const void* /*mi*/) { Seen(kTem); return 1; }

uint8_t hook_Debitar(int32_t /*centavos*/, void* /*rotulo*/, int32_t /*tipo*/, const void* /*mi*/) { Seen(kDebitar); return 1; }

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

bool ModuleFromIndex(uint32_t i, ModuleInfo& out) {
    const char* p = _dyld_get_image_name(i);
    auto* h = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
    if (!p || !h || h->magic != MH_MAGIC_64) return false;
    unsigned long size = 0;
    uint8_t* text = getsegmentdata(h, "__TEXT", &size);
    if (!text || size == 0) return false;
    out.path     = p;
    out.slide    = _dyld_get_image_vmaddr_slide(i);
    out.textBase = reinterpret_cast<uintptr_t>(text);
    out.textSize = size;
    return true;
}

bool FindModuleByName(const char* name, ModuleInfo& out) {
    const uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
        const char* p = _dyld_get_image_name(i);
        if (!p) continue;
        const char* base = std::strrchr(p, '/');
        base = base ? base + 1 : p;
        if (std::strcmp(base, name) == 0 && ModuleFromIndex(i, out)) return true;
    }
    return false;
}

bool ExportsSymbol(const std::string& path, const char* sym) {
    void* h = dlopen(path.c_str(), RTLD_NOLOAD | RTLD_LAZY);
    if (!h) return false;
    const bool ok = dlsym(h, sym) != nullptr;
    dlclose(h);
    return ok;
}

// Fallback when the Unity module is not called UnityFramework (e.g. il2cpp linked into the main binary).
bool FindModuleExportingIl2cpp(ModuleInfo& out) {
    const uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
        const char* p = _dyld_get_image_name(i);
        if (!p || !std::strstr(p, ".app/")) continue; // app bundle images only
        ModuleInfo m;
        if (ModuleFromIndex(i, m) && ExportsSymbol(m.path, "il2cpp_domain_get")) { out = m; return true; }
    }
    return false;
}

void LogAppImages() {
    const uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
        const char* p = _dyld_get_image_name(i);
        if (p && std::strstr(p, ".app/")) Logf("app image: %s", p);
    }
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
        bool ok = true;
        auto sym = [&](const char* nm, auto& dst) {
            dst = reinterpret_cast<std::remove_reference_t<decltype(dst)>>(dlsym(h, nm));
            if (!dst) { Logf("missing export: %s", nm); ok = false; }
        };
        sym("il2cpp_domain_get", domain_get);
        sym("il2cpp_domain_get_assemblies", domain_get_assemblies);
        sym("il2cpp_assembly_get_image", assembly_get_image);
        sym("il2cpp_image_get_name", image_get_name);
        sym("il2cpp_class_from_name", class_from_name);
        sym("il2cpp_class_get_method_from_name", class_get_method_from_name);
        sym("il2cpp_thread_attach", thread_attach);
        sym("il2cpp_thread_detach", thread_detach);
        dlclose(h);
        return ok;
    }

    // Finds the game image; logs the assembly list once when it is not there.
    void* FindGameImage(void* domain, bool logIfMissing) const {
        size_t count = 0;
        void** assemblies = domain_get_assemblies(domain, &count);
        if (!assemblies || count == 0 || count > 4096) { if (logIfMissing) Logf("domain has no assemblies yet (count=%zu)", count); return nullptr; }
        for (size_t i = 0; i < count; ++i) {
            void* image = assembly_get_image(assemblies[i]);
            const char* nm = image ? image_get_name(image) : nullptr;
            if (nm && std::strcmp(nm, cfg::kGameImageName) == 0) return image;
        }
        if (logIfMissing) {
            Logf("image %s not found among %zu assemblies:", cfg::kGameImageName, count);
            for (size_t i = 0; i < count && i < 80; ++i) {
                void* image = assembly_get_image(assemblies[i]);
                Logf("  assembly: %s", image && image_get_name(image) ? image_get_name(image) : "(null)");
            }
        }
        return nullptr;
    }

    // MethodInfo's first field is methodPointer. Returns the PAC-stripped native address or 0.
    uintptr_t ResolveMethod(void* image, const char* ns, const char* cls, const char* method, int argc, const char** why) const {
        void* klass = class_from_name(image, ns, cls);
        if (!klass) { *why = "class not found"; return 0; }
        const void* mi = class_get_method_from_name(klass, method, argc);
        if (!mi) { *why = "method not found (name/argc)"; return 0; }
        const uintptr_t p = StripPac(*reinterpret_cast<const uintptr_t*>(mi));
        if (!p) *why = "methodPointer is null";
        return p;
    }
};

// ---------- install ----------

struct Target {
    HookId      id;
    int         argc;
    uint64_t    dumpVa;
    void*       hook;
    void**      orig; // null when the original is never called
};

const Target kTargets[] = {
    {kGetSCentavos, 0, cfg::kVaGetSCentavos, reinterpret_cast<void*>(&hook_get_s_Centavos), reinterpret_cast<void**>(&orig_get_s_Centavos)},
    {kGetCentavos,  0, cfg::kVaGetCentavos,  reinterpret_cast<void*>(&hook_get_Centavos),   reinterpret_cast<void**>(&orig_get_Centavos)},
    {kGetReais,     0, cfg::kVaGetReais,     reinterpret_cast<void*>(&hook_get_Reais),      reinterpret_cast<void**>(&orig_get_Reais)},
    {kTem,          1, cfg::kVaTem,          reinterpret_cast<void*>(&hook_Tem),            nullptr},
    {kDebitar,      3, cfg::kVaDebitar,      reinterpret_cast<void*>(&hook_Debitar),        nullptr},
};
constexpr size_t kTargetCount = sizeof(kTargets) / sizeof(kTargets[0]);

// All addresses are resolved and validated first; nothing is patched unless every one is valid.
// `api` null = il2cpp exports unavailable, dump VAs are used (UNVERIFIED against the installed build).
bool Install(const ModuleInfo& m, const Il2cppApi* api, void* domain, bool firstTry) {
    void* image = nullptr;
    if (api) {
        image = api->FindGameImage(domain, firstTry);
        if (!image) return false;
    }
    uintptr_t addr[kTargetCount] = {};
    for (size_t i = 0; i < kTargetCount; ++i) {
        const Target& t = kTargets[i];
        const char* name = kHookNames[t.id];
        const uintptr_t viaDump = static_cast<uintptr_t>(m.slide) + static_cast<uintptr_t>(t.dumpVa);
        if (api) {
            const char* why = "";
            const uintptr_t viaApi = api->ResolveMethod(image, cfg::kNamespace, cfg::kClass, name, t.argc, &why);
            if (!viaApi) { if (firstTry) Logf("%s: %s", name, why); return false; }
            if (!InText(m, viaApi)) { Logf("%s: il2cpp address 0x%lx outside __TEXT, rejected", name, (unsigned long)viaApi); return false; }
            if (viaApi != viaDump) Logf("%s: il2cpp 0x%lx != dump 0x%lx -> game build differs from dump, using il2cpp address", name, (unsigned long)viaApi, (unsigned long)viaDump);
            else Logf("%s: il2cpp address matches dump VA 0x%lx", name, (unsigned long)viaApi);
            addr[i] = viaApi;
        } else {
            if (!InText(m, viaDump)) { Logf("%s: dump VA 0x%lx outside __TEXT, rejected", name, (unsigned long)viaDump); return false; }
            Logf("%s: il2cpp API unavailable, UNVERIFIED dump VA 0x%lx", name, (unsigned long)viaDump);
            addr[i] = viaDump;
        }
    }
    for (size_t i = 0; i < kTargetCount; ++i)
        MSHookFunction(reinterpret_cast<void*>(addr[i]), kTargets[i].hook, kTargets[i].orig);
    for (size_t i = 0; i < kTargetCount; ++i) Logf("hooked %s at 0x%lx", kHookNames[kTargets[i].id], (unsigned long)addr[i]);
    return true;
}

void Heartbeat() {
    for (int i = 0; i < cfg::kHeartbeatCount; ++i) {
        sleep(10);
        Logf("calls: get_s_Centavos=%u get_Centavos=%u get_Reais=%u Tem=%u Debitar=%u",
             gCalls[kGetSCentavos].load(), gCalls[kGetCentavos].load(), gCalls[kGetReais].load(),
             gCalls[kTem].load(), gCalls[kDebitar].load());
    }
}

void Worker() {
    Logf("worker started (v1.0.1), pid=%d", (int)getpid());
    bool imagesLogged = false;
    for (int attempt = 0; attempt < cfg::kPollMaxTries; ++attempt) {
        const bool first = attempt == 0 || attempt % 20 == 0; // log failure reasons now and then, not every 500 ms
        ModuleInfo m;
        bool found = FindModuleByName(cfg::kUnityModuleName, m);
        if (!found && attempt >= cfg::kScanAllImagesAfterTries) {
            if (!imagesLogged) { LogAppImages(); imagesLogged = true; }
            found = FindModuleExportingIl2cpp(m);
            if (found) Logf("using %s (exports il2cpp_*), not %s", m.path.c_str(), cfg::kUnityModuleName);
        }
        if (found) {
            Il2cppApi api;
            if (!api.Load(m.path)) {
                Logf("il2cpp exports incomplete in %s -> falling back to dump VAs", m.path.c_str());
                if (Install(m, nullptr, nullptr, true)) { Heartbeat(); }
                return;
            }
            if (void* domain = api.domain_get()) {
                void* thread = api.thread_attach(domain);
                const bool ok = Install(m, &api, domain, first);
                if (thread) api.thread_detach(thread);
                if (ok) { Heartbeat(); return; }
            } else if (first) {
                Logf("il2cpp domain not created yet");
            }
        } else if (first) {
            Logf("module %s not loaded yet (attempt %d)", cfg::kUnityModuleName, attempt);
        }
        usleep(cfg::kPollIntervalMs * 1000);
    }
    Logf("gave up after %d tries", cfg::kPollMaxTries);
}

} // namespace

__attribute__((constructor)) static void TweakInit() {
    static std::atomic<bool> started{false};
    if (started.exchange(true)) return;
    std::thread(Worker).detach();
}
