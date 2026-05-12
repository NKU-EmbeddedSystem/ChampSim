/*
 * BBV (Basic Block Vector) collection tool for Pin.
 * Generates SimPoint-compatible frequency vector files.
 *
 * Collects instruction-weighted basic block execution counts
 * at fixed global instruction intervals (default 100M).
 *
 * Optimized: no lock on the fast path. Safe for single-threaded
 * programs. Use -mt flag to enable lock for multi-threaded programs.
 */

#include <fstream>
#include <iostream>
#include <map>
#include <string>

#include "pin.H"

/* ===================================================================== */
// Command line switches
/* ===================================================================== */
KNOB<std::string> KnobOutputFile(KNOB_MODE_WRITEONCE, "pintool", "o", "output.bb",
                                  "Output BBV file name");

KNOB<UINT64> KnobIntervalSize(KNOB_MODE_WRITEONCE, "pintool", "i", "100000000",
                               "Instructions per interval");

KNOB<BOOL> KnobMultiThreaded(KNOB_MODE_WRITEONCE, "pintool", "mt", "0",
                              "Enable lock for multi-threaded safety");

/* ===================================================================== */
// Global state
/* ===================================================================== */

std::ofstream bbv_file;
PIN_LOCK bbv_lock;
BOOL use_lock = false;

// BBL address -> unique integer ID (1-based)
std::map<ADDRINT, UINT32> bbl_to_id;
UINT32 next_bbl_id = 1;

// Current interval counters
std::map<UINT32, UINT64> interval_counts;
UINT64 interval_insns = 0;
UINT32 current_interval = 0;

UINT64 interval_size = 100000000;

/* ===================================================================== */
// Utilities
/* ===================================================================== */
INT32 Usage() {
    std::cerr << "BBV collection tool for SimPoints" << std::endl
              << "  -o <file>    Output BBV file (default: output.bb)" << std::endl
              << "  -i <N>       Instructions per interval (default: 100000000)" << std::endl
              << "  -mt <0|1>    Multi-threaded safety (default: 0)" << std::endl
              << std::endl;
    return -1;
}

static void DumpInterval() {
    bbv_file << "T";
    for (auto& kv : interval_counts) {
        bbv_file << ":" << kv.first << ":" << kv.second;
    }
    bbv_file << std::endl;

    interval_counts.clear();
    interval_insns = 0;
    current_interval++;
}

/* ===================================================================== */
// Analysis routine - called before every BBL execution
/* ===================================================================== */

VOID BblExecuted(UINT32 bbl_id, UINT32 num_insns) {
    if (use_lock) PIN_GetLock(&bbv_lock, 0);

    interval_counts[bbl_id] += num_insns;
    interval_insns += num_insns;

    if (interval_insns >= interval_size) {
        DumpInterval();
    }

    if (use_lock) PIN_ReleaseLock(&bbv_lock);
}

/* ===================================================================== */
// Instrumentation - assign IDs to BBLs and insert analysis calls
/* ===================================================================== */

VOID Trace(TRACE trace, VOID* v) {
    for (BBL bbl = TRACE_BblHead(trace); BBL_Valid(bbl); bbl = BBL_Next(bbl)) {
        ADDRINT bbl_addr = BBL_Address(bbl);

        // Assign unique ID (lock always used here since this runs once per BBL)
        PIN_GetLock(&bbv_lock, 0);
        if (bbl_to_id.find(bbl_addr) == bbl_to_id.end()) {
            bbl_to_id[bbl_addr] = next_bbl_id++;
        }
        UINT32 bbl_id = bbl_to_id[bbl_addr];
        PIN_ReleaseLock(&bbv_lock);

        BBL_InsertCall(bbl, IPOINT_BEFORE, (AFUNPTR)BblExecuted,
                       IARG_UINT32, bbl_id,
                       IARG_UINT32, BBL_NumIns(bbl),
                       IARG_END);
    }
}

/* ===================================================================== */
// Finalization
/* ===================================================================== */

VOID Fini(INT32 code, VOID* v) {
    if (use_lock) PIN_GetLock(&bbv_lock, 0);
    if (!interval_counts.empty()) {
        DumpInterval();
    }
    if (use_lock) PIN_ReleaseLock(&bbv_lock);

    bbv_file.close();
    std::cerr << "BBV collection done: " << current_interval << " intervals, "
              << next_bbl_id - 1 << " unique BBLs" << std::endl;
}

/* ===================================================================== */
// Main
/* ===================================================================== */

int main(int argc, char* argv[]) {
    PIN_InitSymbols();

    if (PIN_Init(argc, argv)) {
        return Usage();
    }

    interval_size = KnobIntervalSize.Value();
    use_lock = KnobMultiThreaded.Value();

    bbv_file.open(KnobOutputFile.Value().c_str());
    if (!bbv_file.is_open()) {
        std::cerr << "Error: cannot open output file " << KnobOutputFile.Value() << std::endl;
        return 1;
    }
    bbv_file << std::unitbuf;

    PIN_InitLock(&bbv_lock);

    TRACE_AddInstrumentFunction(Trace, 0);
    PIN_AddFiniFunction(Fini, 0);

    std::cerr << "BBV tool: interval=" << interval_size
              << " output=" << KnobOutputFile.Value()
              << " mt=" << use_lock << std::endl;

    PIN_StartProgram();
    return 0;
}
