#pragma once
#include <cstdint>

// Everything build-dependent lives here.
// Source of every VA below: dump_cs.txt uploaded by the user (Il2CppDumper output).
// The dump does not state the game version/build it came from -> build identity UNKNOWN.
// VAs are runtime-address = image slide + VA (the dump prints RVA == VA, i.e. image base 0).
// They are only a FALLBACK: the primary path resolves methods by name through the il2cpp API.
namespace cfg {

// Assumed from the standard Unity iOS layout (UnityFramework.framework). Not verified on the device.
inline constexpr const char* kUnityModuleName = "UnityFramework";
inline constexpr const char* kGameImageName   = "Assembly-CSharp.dll"; // dump: "Image 0: Assembly-CSharp.dll"

// Wallet is an int in centavos (AtlasEconomia.Carteira.Centavos). 1'000'000'000 = R$ 10.000.000,00.
// Must stay well below INT32_MAX (2'147'483'647) so game-side additions cannot overflow.
inline constexpr int32_t kBalanceFloorCentavos = 1'000'000'000;

inline constexpr int kPollIntervalMs = 500;
inline constexpr int kPollMaxTries   = 240; // 2 minutes
inline constexpr int kScanAllImagesAfterTries = 10; // then look for any app image exporting il2cpp_*
inline constexpr int kHeartbeatCount = 6;           // call-count log lines after install, 10 s apart

// AtlasEconomia.Carteira, Assembly-CSharp, namespace "AtlasEconomia"
inline constexpr const char* kNamespace = "AtlasEconomia";
inline constexpr const char* kClass     = "Carteira";

inline constexpr uint64_t kVaGetCentavos  = 0x26B05F8; // public static int get_Centavos()
inline constexpr uint64_t kVaGetReais     = 0x26B06B8; // public static float get_Reais()
inline constexpr uint64_t kVaGetSCentavos = 0x26AFE5C; // private static int get_s_Centavos()
inline constexpr uint64_t kVaTem          = 0x26B1388; // public static bool Tem(int centavos)
inline constexpr uint64_t kVaDebitar      = 0x26B1304; // public static bool Debitar(int centavos, string rotulo, TipoDeLancamento tipo)

} // namespace cfg
