# ProjetoGrau2Cash

Rootless Theos tweak (iOS 16.x jailbreak, ElleKit/Substrate) that gives Projeto Grau 2 an effectively infinite wallet.

Build: GitHub > Actions > "Build tweak" > Run workflow, enter the game's bundle id. Download the `.deb` artifact and install it.

Behavior
- `Carteira.s_Centavos` getter never returns less than `kBalanceFloorCentavos` (Config.h), real earnings above it are kept.
- `Carteira.Tem` always true, `Carteira.Debitar` always succeeds without deducting.
- Methods are found by name through the il2cpp API; dump VAs in Config.h are only a fallback.
