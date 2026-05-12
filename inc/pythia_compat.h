#ifndef PYTHIA_COMPAT_H
#define PYTHIA_COMPAT_H

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cassert>
#include <cmath>
#include <algorithm>
#include <iostream>
#include <vector>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <random>
#include <fstream>
#include <iomanip>
#include <limits>

// ── Page/block constants from ChampSim ────────────────────────────────
// BLOCK_SIZE, PAGE_SIZE, LOG2_BLOCK_SIZE, LOG2_PAGE_SIZE are extern const
// in ChampSim's champsim.h — included via modules.h already

// ── Pythia legacy Prefetcher base (replaced by pythia_adapter.h) ───
// This file provides type compatibility only.
// Actual base class is in pythia_adapter.h

// ── Common typedefs for ported code ─────────────────────────────────
using std::vector;
using std::deque;
using std::map;
using std::set;
using std::string;
using std::cout;
using std::cerr;
using std::endl;

// ── Stub macros that Pythia code references ─────────────────────────
#define SANITY_CHECK
#define DP(x) x

// ── bzero is provided by <cstring> / system headers ──────────────────

#endif
