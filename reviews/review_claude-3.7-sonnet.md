# ISSCC Peer Review

## 1. SUMMARY

This paper presents an HW/SW co-design for Seq2Seq neural machine translation (German→English, Multi30K dataset) on a TSMC 28nm RISC-V (RV32IM) processor. The central claimed contribution is a workload-aware scratchpad memory (SPM) bypass path that eliminates cache tag comparison energy for streaming GEMV accelerator access patterns. The authors argue that direct-mapped cache hit rate is provably zero for streaming matrix access, making every tag comparison pure energy waste. The staged optimization pipeline progresses from an LSTM baseline through a Transformer architecture with 128KB SPM, DMA controller, KV cache management, and 8-way parallel MAC. Headline claimed results include: >4× CPI reduction, cache tag energy reduction to ~0%, BLEU ≥ 15 on Multi30K, and latency reduction from 4 cycles to 1 cycle for SPM accesses. Critically, **all results in Table II are explicitly labeled as "expected" — no measured silicon or post-synthesis results are presented.**

---

## 2. STRENGTHS

- **Clear analytical framework**: The decomposition of GEMV access patterns into streaming (W) and temporal-reuse (x) components in Section III is well-reasoned and provides a principled motivation for cache bypass.
- **Honest ablation structure**: The staged optimization methodology (Stages 0–5) with one variable changed per stage is methodologically sound in principle, enabling clean isolation of each contribution.
- **Relevant problem identification**: The observation that clock (58.3%) and memory (38.0%) dominate power while computation (2.1%) is negligible aligns with well-established energy scaling arguments (Horowitz, ISSCC 2014 [6]).
- **Conflict miss analysis**: The specific analysis showing that W and x map to overlapping cache index bits [10:2] for K=256, causing mutual eviction, is a concrete and verifiable claim.

---

## 3. EVALUATION ON ISSCC CRITERIA

### a. Innovation/Significance — Score: 1/5

**Justification**: The core idea — bypassing cache for streaming/non-temporal data and using software-managed scratchpad memory — is not novel. Banakar et al. [4] (CODES 2002) established SPM energy advantages over 20 years ago. Non-temporal memory hints and streaming bypass are standard features in modern processors (Intel's CLFLUSHOPT, ARM's non-cacheable memory attributes, CUDA's `__ldg` and bypass paths). The specific claim of "hardware-directed address-based routing" for a RISC-V MMIO accelerator DMA path is incremental at best. The authors themselves acknowledge in Table I that Kim et al. [14] already demonstrated HW cache bypass with principled analysis. The combination of (RISC-V + cache analysis + SPM bypass + KV cache) is presented as novel, but this combination represents straightforward engineering application of well-known principles to a specific course project platform (AS501), not a research contribution at ISSCC caliber. The Transformer KV cache management for a 128-dim, 29M parameter model on an embedded RISC-V is orders of magnitude below the scale of relevant ISSCC submissions (e.g., TRAPTI [11], Titanus [12]).

### b. Technical Paper Quality — Score: 1/5

**Justification**: This is the most critical failure. **The paper presents zero measured results.** Every number in Table II is explicitly "expected" performance. The abstract states the system "targets BLEU ≥ 15 with > 4× CPI reduction" — future tense. Section V is titled "Evaluation Plan" (not "Evaluation Results"). Section VII is a project timeline. The paper is a **design proposal**, not a completed research contribution. ISSCC requires measured silicon results or, at minimum, complete post-synthesis/post-layout simulation results with validated power numbers. The authors state "Each RTL simulation requires approximately 24 hours per sentence" and budget "6–8 simulation runs across 6 weeks" — indicating the work is not complete. The power analysis claim of "58.3% clock, 38.0% memory" appears to be from the baseline only, with no comparative post-synthesis numbers for Stages 1–5. The BLEU ~48 for the baseline LSTM (Stage 0) is suspicious and unexplained — BLEU of 48 on Multi30K German→English would be state-of-the-art for a 2-layer LSTM, suggesting a measurement or reporting error. No silicon micrograph, no measured waveforms, no complete power breakdown table with actual numbers.

### c. Clarity of Figures and Text — Score: 2/5

**Justification**: The writing is clear and well-organized for a technical report, but the paper lacks essential figures for an ISSCC submission: no architecture block diagram of the bypass path, no timing diagram showing the 4-cycle vs. 1-cycle access, no cache conflict miss visualization, no power breakdown charts with measured data, no die photo or layout. Table I (prior art comparison) uses binary checkmarks without quantitative comparison. Table II contains only projected numbers with no confidence intervals or simulation methodology. The 11,000-character limit appears respected, but the content is a proposal rather than a completed paper. The "■" symbols in Section III.A (likely rendering artifacts for matrix dimension notation) indicate incomplete manuscript preparation.

---

## 4. MAJOR CONCERNS

**M1 — No Measured Results (Fatal Flaw)**: The paper contains exclusively projected/expected results. ISSCC explicitly requires demonstrated results. Section V ("Evaluation Plan"), Section VII ("Timeline"), and Table II ("Expected Performance") confirm this is an incomplete proposal. This alone warrants rejection.

**M2 — BLEU Score Anomaly**: Stage 0 reports BLEU ~48 for a 2-layer LSTM on Multi30K German→English. Published state-of-the-art for this benchmark with LSTM models is typically 30–38 BLEU. A score of 48 suggests either (a) the metric is computed incorrectly (e.g., on training set, or with incorrect tokenization), (b) the model is overfitted, or (c) a reporting error. This undermines confidence in all BLEU claims. The paper does not explain this anomaly.

**M3 — Core Contribution is Trivially Known**: The claim that streaming access patterns achieve zero cache hit rate in direct-mapped caches is not a novel finding — it is a textbook result. The "principled analysis" in Section III, while clearly presented, derives a known result (conflict misses between matrix rows and vectors in direct-mapped caches) without new mathematical insight. The bypass solution is a standard non-cacheable memory region, implemented in thousands of embedded systems.

**M4 — Tag Energy Quantification Lacks Rigor**: The claim of "0.5–1.0 pJ per tag access in TSMC 28nm" cites Horowitz [6] generically, but Horowitz's data is for SRAM reads, not specifically tag array accesses. No SPICE simulation, no memory compiler characterization, and no synthesis report supports this number. The "2.6M wasted tag comparisons per sentence" calculation assumes specific cache parameters not fully specified (cache size, associativity, line size).

**M5 — Unfair/Incomplete Prior Art Comparison**: Table I uses binary feature presence/absence without quantitative comparison. The paper claims the combination of features is novel, but does not quantitatively compare energy efficiency, area overhead, or performance against any prior work. For ISSCC, a Figure-of-Merit comparison table with normalized metrics (e.g., TOPS/W, energy per inference, area efficiency) is essential.

**M6 — Stage 1 CPI Regression Unexplained**: Table II shows Stage 1 (Transformer SW) has 3.0× *worse* CPI than Stage 0 (LSTM baseline). This regression is not analyzed. If the Transformer is 3× slower in software, the motivation for the architecture switch (Section IV.A) — which claims hardware utilization efficiency — is undermined without the hardware stages.

**M7 — Bypass Path Architecture Underspecified**: The "address-based routing path in the GEMV DMA interface" is described only in prose. No RTL snippet, no block diagram, no timing specification, and no area overhead number is provided. The claim of 4-cycle to 1-cycle latency reduction is unsubstantiated without a memory timing diagram or synthesis report.

**M8 — Course Project Context**: Multiple references to "AS501 (2024)" course, "prior teams," "make server command," and "6-week timeline" strongly suggest this is a graduate course project submission rather than original research. ISSCC submissions must represent original research contributions, not course assignments.

**M9 — KV Cache Sizing Inconsistency**: The paper claims KV cache occupies ~80KB of the 128KB SPM, leaving ~46KB for weight tiles. For a Transformer with d_model=128, 4 heads, 2 decoder layers, and maximum sequence length of ~50 tokens: K and V matrices per layer are 50×128×4 bytes = 25.6KB per layer × 2 layers × 2 (K+V) = 102.4KB. This exceeds the claimed 80KB allocation. The sizing calculation is not shown and appears inconsistent.

---

## 5. MINOR CONCERNS

**m1 — Rendering Artifacts**: "■^{M×K}" in Section III.A indicates LaTeX rendering failure. Matrix dimensions are not properly displayed.

**m2 — Reference Quality**: References [9], [10], [11], [13] are arXiv preprints, not peer-reviewed publications. Reference [11] (TRAPTI, arXiv:2604.06955) has an implausible date (April 2026 implied by numbering). Reference [15] is a 2007 arXiv preprint, not a published paper.

**m3 — Double-Blind Violation**: The paper identifies the institution (KAIST, Graduate School of AI Semiconductor) and course (AS501) explicitly, violating double-blind review requirements if applicable.

**m4 — Missing Figures**: An ISSCC paper without architecture diagrams, measured waveforms, or layout photos is incomplete. The paper has no figures at all based on the submitted text.

**m5 — Horowitz Citation Misuse**: Citing Horowitz [6] for "10–100× data movement energy over computation" is appropriate, but the paper uses this as a blanket justification without quantifying the specific ratio for their workload.

**m6 — Stage 5 Feasibility**: Newton-Raphson sqrt for LayerNorm and base-2 exp LUT for Softmax are mentioned as "stretch" goals with "~6× speedup" but no analysis of numerical accuracy, LUT size, or convergence criteria is provided.

---

## 6. RECOMMENDATION

**Reject.**

This manuscript is an incomplete graduate course project proposal containing exclusively projected results, no measured silicon or validated post-synthesis data, a trivially known core technical contribution (cache bypass for streaming access), and fundamental methodological gaps that preclude evaluation as an ISSCC research contribution.