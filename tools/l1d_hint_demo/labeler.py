#!/usr/bin/env python3
"""Unified, config-driven hint labeler.

Every labeling rule in the x10 study is one point in a single parameter
space: a SCORE stage ranks the 13 candidates (12 policies + OFF) per PC,
a SELECT stage picks one (with a tie policy), and an optional GATE stage
demotes selections after the fact. This module declares that space
(PARAM_SPACE), gives every historical scheme as a named preset (PRESETS,
byte-identical to the bins relabel_hint_bw.py has produced), and exposes
one pure entry point:

    make_labels(cell: CellData, cfg: dict) -> [{"pc", "best_prefetch",
                                                "best_degree"}]

The module is I/O-free on purpose: the driver (relabel_hint_bw.py) and
the optimizer harness (eval_labeler.py) load data, populate a CellData,
and call make_labels. An RL/Bayesian optimizer only needs PARAM_SPACE
(bounds), a config dict (the action), and the harness reward.

Pipeline stages and the config keys that control them:

  score ("tax" | "oracle" | "pigou")
    "tax":    score(key) = amat * (1 + lam_w*twaste + churn_w*churn
                                    + lam_i*ipc_gap + lam_l2*l2_gap);
              the 'no' candidate pays lam_i*ipc_gap_no (symmetric
              opportunity-cost tax - without it OFF over-shuts
              prefetch-friendly traces: sphinx3@1600 -12.4%).
    "oracle": trust the ground truth's best_prefetch field (Scheme B's
              3200-label reuse), non-candidates fall back to sandbox:1.
    "pigou":  select argmax Pigouvian net instead of argmin taxed AMAT
              (Scheme C; nets precomputed by the driver).
  tie_policy ("gb" | "no"): tied PCs (all candidate AMATs equal - cold
    PCs, no per-PC signal) get the trace-wide best key or OFF.
  gate ("none" | "waste" | "pigou")
    "waste": accuracy-waste > gate_theta -> same family, lowest tier
      (tied PCs exempt - they carry the trace-wide best, and Scheme B
      never gated it).
    "pigou": demote to OFF when the ledger convicts the label, under
      three jurisdiction switches (all ablation-validated, see
      pigou_gate_labels docstring in relabel_hint_bw.py):
        pg_tied_exempt  - tied PCs exempt (sphinx3 collapse without it)
        pg_toxic_only   - only isolated-toxic families (dC > 0) are
                          gated (cactusADM/lbm/milc false demotions)
        pg_mix_rescue   - outside poison habitats, a PC whose seg-sim
                          record shows real benefit keeps its label
                          (mcf bw800 -17.8% without it)
      plus pg_net_thresh (demote when net <= thresh),
      pg_rescue_margin (benefit = amat_mix < margin * amat_no), and
      pg_habitat ("auto": wci mix < no from seg outputs).
  base ("score" | "wci_bin"): pigou gate starts from the scored
    selection or from the labels in an existing wci hint.bin (the
    historical Scheme D data flow).
"""

# ── 12-policy candidate set + OFF sentinel (see oracle_gen.py) ──
CANDIDATE_FAMILIES = {
    "sandbox": [1, 4, 8],
    "dspatch": [1, 16, 64],
    "mlop": [1, 8, 16],
    "stream": [1, 4, 8],
}
CANDIDATE_KEYS = {(pf, deg) for pf, degs in CANDIDATE_FAMILIES.items() for deg in degs}
GATE_FALLBACK = ("sandbox", 1)  # lowest tier, policy index 0
NO_KEY = "no:1"

# ── optimizer-facing parameter space ──
# (name, kind, bounds/choices, default). Kinds: float, bool, cat.
PARAM_SPACE = [
    ("score",            "cat",   ("tax", "oracle", "pigou"),      "tax"),
    ("lam_w",            "float", (0.0, 2.0),                      0.5),
    ("churn_w",          "float", (0.0, 2.0),                      1.0),
    ("lam_i",            "float", (0.0, 2.0),                      0.5),
    ("lam_l2",           "float", (0.0, 1.0),                      0.0),
    ("tie_policy",       "cat",   ("gb", "no"),                    "gb"),
    ("base",             "cat",   ("score", "wci_bin"),            "score"),
    ("gate",             "cat",   ("none", "waste", "pigou"),      "none"),
    ("gate_theta",       "float", (0.5, 1.0),                      0.9),
    ("pg_tied_exempt",   "bool",  None,                            True),
    ("pg_toxic_only",    "bool",  None,                            True),
    ("pg_mix_rescue",    "bool",  None,                            True),
    ("pg_rescue_margin", "float", (0.98, 1.0),                     0.995),
    ("pg_habitat",       "cat",   ("auto", "always", "never"),     "auto"),
    ("pg_net_thresh",    "float", (-10000.0, 0.0),                 0.0),
]
DEFAULT_CONFIG = {name: default for name, _, _, default in PARAM_SPACE}


def _cfg(**over):
    c = dict(DEFAULT_CONFIG)
    c.update(over)
    return c


# Historical schemes as points in the space. Bin names are assigned by
# the driver (hint_tax_<name>.bin; gate_t90 -> hint_gate_t90.bin).
PRESETS = {
    # raw per-PC AMAT argmin, no tax (the pre-tax baseline)
    "hint": _cfg(lam_w=0.0, churn_w=0.0, lam_i=0.0),
    # tax ablation ladder (w/wc/wci)
    "w":   _cfg(churn_w=0.0, lam_i=0.0),
    "wc":  _cfg(lam_i=0.0),
    "wci": _cfg(),
    # Scheme B: 3200 oracle label + accuracy-waste gate at the target bw
    "gate_t90": _cfg(score="oracle", gate="waste", gate_theta=0.9),
    # Scheme C: argmax Pigouvian net
    "pigou": _cfg(score="pigou"),
    # Scheme D lineage: wci bin + ledger gate. pigougate == v7 (final).
    "pigougate_v5": _cfg(base="wci_bin", gate="pigou",
                         pg_tied_exempt=True, pg_toxic_only=False,
                         pg_mix_rescue=False),
    "pigougate_v6": _cfg(base="wci_bin", gate="pigou",
                         pg_tied_exempt=True, pg_toxic_only=True,
                         pg_mix_rescue=False),
    "pigougate": _cfg(base="wci_bin", gate="pigou"),
}


def is_candidate(pf, deg):
    return (pf, deg) in CANDIDATE_KEYS


def pigou_net(gt, weights, useless, ipcs, no_ipcs, tname, bw):
    """Per-(pc, policy) net benefit under Pigouvian accounting.

        G(P)  = sum_j w_j * max(0, amat_j(no) - amat_j(P))   # gainers
        V(P)  = sum_j w_j * max(0, amat_j(P) - amat_j(no))   # victims
        rho(P) = dC(P) / (V(P) - G(P))    # AMAT -> IPC conversion rate
        net_i(P) = rho * [ (amat_i(no) - amat_i(P)) * w_i
                           - V * u_i(P) / U(P) ]

    Conservation: sum_i net_i(P) = rho*(G - V) = -dC(P), so the ledger
    exactly reproduces each policy's global cycle delta. rho is measured
    on the isolated single-policy runs (povray ~0.003: 99.7% of nominal
    AMAT-cycles are hidden by out-of-order overlap). Returns
    {pc: {"pf:deg": net}} with 'no' implicit at 0.
    """
    ptab = {}
    for pf, degs in CANDIDATE_FAMILIES.items():
        for deg in degs:
            key = f"{pf}:{deg}"
            G = V = 0.0
            U = 0
            for pc, rec in gt.items():
                amats = rec.get("all_amats") or {}
                a_p = float(amats.get(key, 0.0) or 0.0)
                a_n = float(amats.get("no:1", 0.0) or 0.0)
                w = weights.get(pc, 0)
                if a_p <= 0.0 or a_n <= 0.0 or w <= 0:
                    continue
                d = (a_p - a_n) * w
                if d > 0:
                    V += d
                else:
                    G += -d
                U += useless.get((pc, key), 0)
            ptab[key] = (G, V, U)

    rho = {}
    for key in ptab:
        pf, deg = key.rsplit(":", 1)
        ipc_p = ipcs.get((tname, policy_to_stat_name(pf, int(deg)), bw))
        ipc_n = no_ipcs.get((tname, bw))
        if not (ipc_p and ipc_n):
            continue
        G, V, U = ptab[key]
        d_amat = V - G
        if d_amat == 0.0:
            continue
        r = (1e8 / ipc_p - 1e8 / ipc_n) / d_amat
        if r > 0.0:
            rho[key] = r  # negative: AMAT moves against cycles - distrust

    nets = {}
    for pc, rec in gt.items():
        amats = rec.get("all_amats") or {}
        a_n = float(amats.get("no:1", 0.0) or 0.0)
        w = weights.get(pc, 0)
        if a_n <= 0.0 or w <= 0:
            continue
        row = {}
        for key, a_p in amats.items():
            pf, deg = key.rsplit(":", 1)
            if pf == "no" or float(a_p) <= 0.0:
                continue
            if not is_candidate(pf, int(deg)) or key not in rho:
                continue
            G, V, U = ptab[key]
            share = useless.get((pc, key), 0) / U if U > 0 else 0.0
            row[key] = ((a_n - float(a_p)) * w * rho[key]) - V * rho[key] * share
        if row:
            nets[pc] = row
    return nets


def policy_to_stat_name(pf, deg):
    return f"{pf}_d{deg}"


def idx_to_key(idx):
    """Policy index -> 'pf:deg' key ('no:1' for the OFF sentinel)."""
    if idx >= 12:
        return NO_KEY
    keys = [f"{pf}:{deg}" for pf, degs in CANDIDATE_FAMILIES.items() for deg in degs]
    return keys[idx]


def all_amats_tied(rec):
    """True when every positive candidate AMAT is equal — the PC is
    insensitive to the prefetch policy (cold/tail PC)."""
    vals = []
    for key, amat in (rec.get("all_amats") or {}).items():
        pf, deg = key.rsplit(":", 1)
        if not is_candidate(pf, int(deg)):
            continue
        if float(amat) <= 0.0:
            continue
        vals.append(float(amat))
    return len(vals) >= 2 and max(vals) == min(vals)


class CellData:
    """Everything make_labels needs for one (trace, bw) cell. The driver
    populates accessors as closures so the labeler stays pure.

    gt:          {pc_str: record} ground truth for selection
    tie_gt:      ground truth for the tie check (Scheme B: the bw-native
                 gt while gt is the 3200 one); None = same as gt
    gb_key:      trace-wide best "pf:deg" at this bw (tie/fallback)
    twaste(pf,deg)      -> absolute-traffic waste (useless / demand)
    churn(pf,deg)       -> pipeline-occupancy churn tax
    ipc_gap(pf,deg)     -> 1 - ipc/ipc_best (opportunity cost)
    ipc_gap_no:         the same gap for 'no'
    l2_gap(pf,deg)      -> L2-pollution tax (retired, declared)
    waste_acc(pf,deg)   -> accuracy-based waste (1 - useful/issued)
    nets:        {pc: {"pf:deg": net}} Pigouvian ledger (gate="pigou")
    toxic(key)   -> bool: isolated run loses to 'no' (dC > 0)
    wci_sel:     {pc_str: policy_idx} from the wci hint.bin (base=wci_bin)
    mix_ev:      {pc_str: (issued, avg_amat)} seg-sim evidence, or None
    poison_habitat: wci mix loses to 'no' (local benefit untrustworthy)
    """
    def __init__(self, tname, bw, gt, tie_gt=None, gb_key="sandbox:1",
                 twaste=None, churn=None, ipc_gap=None, ipc_gap_no=0.0,
                 l2_gap=None, waste_acc=None, nets=None, toxic=None,
                 wci_sel=None, mix_ev=None, poison_habitat=True):
        self.tname, self.bw, self.gt = tname, bw, gt
        self.tie_gt = tie_gt if tie_gt is not None else gt
        self.gb_key = gb_key
        self.twaste = twaste or (lambda pf, deg: 0.0)
        self.churn = churn or (lambda pf, deg: 0.0)
        self.ipc_gap = ipc_gap or (lambda pf, deg: 0.0)
        self.ipc_gap_no = ipc_gap_no
        self.l2_gap = l2_gap or (lambda pf, deg: 0.0)
        self.waste_acc = waste_acc or (lambda pf, deg: 0.0)
        self.nets = nets or {}
        self.toxic = toxic or (lambda key: True)
        self.wci_sel = wci_sel
        self.mix_ev = mix_ev
        self.poison_habitat = poison_habitat


def _split(key):
    pf, deg = key.rsplit(":", 1)
    return pf, int(deg)


def _emit(labels_by_pc):
    return [{"pc": pc, "best_prefetch": _split(key)[0], "best_degree": _split(key)[1]}
            for pc, key in labels_by_pc]


# ── SCORE/SELECT stages ──

def _select_tax(cell, cfg):
    """Argmin taxed AMAT (the ablation ladder; all-zero weights = raw)."""
    lam_w, churn_w = cfg["lam_w"], cfg["churn_w"]
    lam_i, lam_l2 = cfg["lam_i"], cfg["lam_l2"]
    out = []
    for pc, rec in cell.gt.items():
        if all_amats_tied(rec):
            best_key = cell.gb_key if cfg["tie_policy"] == "gb" else NO_KEY
        else:
            best_key, best_score = None, None
            for key, amat in rec["all_amats"].items():
                pf, deg = _split(key)
                if float(amat) <= 0.0:
                    continue  # no measured data under this policy
                if pf == "no":
                    # OFF pays the same opportunity-cost tax as everyone
                    score = float(amat) * (1.0 + lam_i * cell.ipc_gap_no)
                else:
                    if not is_candidate(pf, deg):  # stale 15-policy labels
                        continue
                    score = float(amat) * (1.0 + lam_w * cell.twaste(pf, deg)
                                           + churn_w * cell.churn(pf, deg)
                                           + lam_i * cell.ipc_gap(pf, deg)
                                           + lam_l2 * cell.l2_gap(pf, deg))
                if best_score is None or score < best_score:
                    best_key, best_score = key, score
            if best_key is None:
                best_key = cell.gb_key  # no data: trace-wide best
        out.append((pc, best_key))
    return out


def _select_oracle(cell, cfg):
    """Trust the ground truth's best_prefetch (Scheme B's 3200 reuse)."""
    out = []
    for pc, rec in cell.gt.items():
        tie_rec = cell.tie_gt.get(pc)
        if tie_rec is not None and all_amats_tied(tie_rec):
            key = cell.gb_key if cfg["tie_policy"] == "gb" else NO_KEY
        else:
            pf, deg = rec["best_prefetch"], int(rec.get("best_degree", 1))
            if not is_candidate(pf, deg):
                pf, deg = GATE_FALLBACK
            key = f"{pf}:{deg}"
        out.append((pc, key))
    return out


def _select_pigou(cell, cfg):
    """Argmax Pigouvian net; 'no' sits at net = 0 (Scheme C)."""
    out = []
    for pc, rec in cell.gt.items():
        if all_amats_tied(rec):
            best_key = cell.gb_key if cfg["tie_policy"] == "gb" else NO_KEY
        else:
            best_key, best_net = NO_KEY, 0.0
            for key, net in cell.nets.get(pc, {}).items():
                if net > best_net:
                    best_key, best_net = key, net
        out.append((pc, best_key))
    return out


_SELECTORS = {"tax": _select_tax, "oracle": _select_oracle, "pigou": _select_pigou}


# ── GATE stages (operate on (pc, key) selections) ──

def _gate_waste(sel, cell, cfg):
    """Accuracy-waste above theta -> same family, lowest tier (Scheme B).

    Tied PCs (no per-PC signal, carrying the trace-wide best) are exempt:
    the historical Scheme B kept the global-best label untouched, and
    demoting it (omnetpp's dspatch gb, waste 0.997) breaks byte-parity."""
    out = []
    for pc, key in sel:
        pf, deg = _split(key)
        tie_rec = cell.tie_gt.get(pc)
        exempt = tie_rec is not None and all_amats_tied(tie_rec)
        if not exempt and pf != "no" and cell.waste_acc(pf, deg) > cfg["gate_theta"]:
            deg = min(CANDIDATE_FAMILIES[pf])
            key = f"{pf}:{deg}"
        out.append((pc, key))
    return out


def _gate_pigou(sel, cell, cfg):
    """Demote ledger-convicted labels to OFF, under the jurisdiction
    switches (see module docstring and relabel_hint_bw.pigou_gate_labels).
    """
    out = []
    for pc, key in sel:
        if key != NO_KEY:
            rec = cell.gt.get(pc, {})
            tied = all_amats_tied(rec) if rec else False
            if cfg["pg_tied_exempt"] and tied:
                out.append((pc, key))
                continue
            if cfg["pg_toxic_only"] and not cell.toxic(key):
                out.append((pc, key))
                continue
            if cell.nets.get(pc, {}).get(key, 0.0) <= cfg["pg_net_thresh"]:
                rescued = False
                if cfg["pg_mix_rescue"] and cell.mix_ev and not cell.poison_habitat:
                    iss, amat_mix = cell.mix_ev.get(pc, (0, None))
                    a_n = (rec.get("all_amats") or {}).get("no:1")
                    rescued = (iss > 0 and a_n is not None
                               and amat_mix is not None
                               and amat_mix < cfg["pg_rescue_margin"] * a_n)
                if not rescued:
                    key = NO_KEY
        out.append((pc, key))
    return out


_GATES = {"none": lambda sel, cell, cfg: sel,
          "waste": _gate_waste,
          "pigou": _gate_pigou}


def make_labels(cell, cfg):
    """One (trace, bw) cell + one config -> the label list for gen_bin."""
    if cfg["gate"] == "pigou" and cfg["base"] == "wci_bin":
        # Historical Scheme D data flow: the selection is read from the
        # wci hint.bin (covers exactly gt's PCs, in gt order).
        sel = [(pc, idx_to_key(cell.wci_sel.get(pc, 12))) for pc in cell.gt]
    else:
        sel = _SELECTORS[cfg["score"]](cell, cfg)
    sel = _GATES[cfg["gate"]](sel, cell, cfg)
    return _emit(sel)


def config_slug(cfg):
    """Stable short tag for a config (bin/output naming in the harness)."""
    import hashlib
    import json
    blob = json.dumps(cfg, sort_keys=True, separators=(",", ":"))
    return hashlib.md5(blob.encode()).hexdigest()[:8]
