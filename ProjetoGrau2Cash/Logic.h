#pragma once
#include <cstdint>

namespace logic {

// The wallet never reads below `floor`; a larger real balance (earned afterwards) is kept as is.
constexpr int32_t ApplyBalanceFloor(int32_t real, int32_t floor) noexcept {
    return real < floor ? floor : real;
}

} // namespace logic
