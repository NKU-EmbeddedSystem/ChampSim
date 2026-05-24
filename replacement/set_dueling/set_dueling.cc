// Explicit template instantiations for supported policy combinations.
// To add a new combination, add a new instantiation here AND add the
// corresponding configuration in the JSON config system.

#include "../lru/lru.h"
#include "../srrip/srrip.h"
#include "../ship/ship.h"
#include "../hawkeye/hawkeye.h"
#include "../mockingjay/mockingJay.h"
#include "set_dueling.h"

// 2-policy combinations
template struct set_dueling<lru, srrip>;
template struct set_dueling<mockingJay, hawkeye>;

// 4-policy combinations
template struct set_dueling<lru, srrip, ship, hawkeye>;
template struct set_dueling<lru, srrip, ship, mockingJay>;
