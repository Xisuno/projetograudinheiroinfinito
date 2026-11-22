#pragma once
#include <cstdint>

namespace logic {

// The wallet never reads below `floor`; a larger real balance (earned afterwards) is kept as is.
constexpr int32_t ApplyBalanceFloor(int32_t real, int32_t floor) noexcept {
    return real < floor ? floor : real;
}

// Same floor for the float getter that reports reais (centavos / 100).
constexpr float ApplyReaisFloor(float real, int32_t floorCentavos) noexcept {
    const float f = static_cast<float>(floorCentavos) / 100.0f;
    return real < f ? f : real;
}

} // namespace logic
