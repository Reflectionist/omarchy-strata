#pragma once

#include "strata.hpp"

namespace Strata {
    bool animInit();
    void animOrder(std::vector<WORKSPACEID> ids, bool wrap);
    bool animWrap(); // vertical wrap, as Lua last said (its setting and the off toggle)
    bool stackNeighbours(WORKSPACEID id, WORKSPACEID& up, WORKSPACEID& down, int* upRow = nullptr, int* downRow = nullptr);
}
