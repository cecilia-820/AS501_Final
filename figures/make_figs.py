"""Generate publication-quality figures for AS501 proposal.
Outputs: <name>.pdf (vector) + <name>.png (300dpi) into ./
"""
import os
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch, ConnectionPatch
import numpy as np

OUT = os.path.dirname(os.path.abspath(__file__))
plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 10,
    "axes.linewidth": 0.8,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
})

def save(fig, name):
    fig.savefig(os.path.join(OUT, f"{name}.pdf"), bbox_inches="tight")
    fig.savefig(os.path.join(OUT, f"{name}.png"), bbox_inches="tight", dpi=300)
    plt.close(fig)
    print(f"  -> {name}.pdf + .png")

# ----------------------------------------------------------------------
# Fig 1: Baseline Power Breakdown (motivation)
# ----------------------------------------------------------------------
def fig1_power_breakdown():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.2, 3.2),
                                    gridspec_kw={"width_ratios": [1, 1.3]})
    labels = ["Clock", "Memory\n(SRAM)", "Logic", "Other"]
    sizes = [58.3, 38.0, 2.1, 1.6]   # sums to 100.0
    colors = ["#4C72B0", "#DD8452", "#55A868", "#BBBBBB"]
    explode = (0.02, 0.02, 0.06, 0.0)
    def fmt(pct):
        return f"{pct:.1f}%" if pct >= 2 else ""
    wedges, texts, autotexts = ax1.pie(
        sizes, labels=labels, colors=colors, explode=explode,
        autopct=fmt, startangle=90,
        wedgeprops=dict(edgecolor="white", linewidth=1.5),
        textprops=dict(fontsize=10),
    )
    for t in autotexts:
        t.set_color("white"); t.set_fontweight("bold")
    ax1.set_title("(a) Baseline dynamic power\n(post-synthesis, TSMC 28nm)",
                  fontsize=10, pad=10)

    ax2.axis("off")
    msg = (
        "Key observation\n"
        "─────────────────\n"
        "• Data movement + clock\n"
        "  account for 96.3% of power\n"
        "• Compute logic is only 2.1%\n\n"
        "Horowitz, ISSCC'14 [6]:\n"
        "  E$_{move}$ / E$_{compute}$ ≈ 10–100×\n\n"
        "→ Optimizing memory access\n"
        "    yields the largest energy win"
    )
    ax2.text(0.0, 0.98, msg, ha="left", va="top", fontsize=10,
             family="DejaVu Sans",
             bbox=dict(boxstyle="round,pad=0.6", fc="#F5F5F5", ec="#888"))
    ax2.set_title("(b) Implication", fontsize=10, pad=10, loc="left")
    fig.suptitle("Fig. 1.  Baseline power breakdown motivates memory-centric optimization.",
                 fontsize=10, y=-0.02)
    save(fig, "fig1_power_breakdown")

# ----------------------------------------------------------------------
# Fig 2: Cache Access Pattern & Conflict Miss
# ----------------------------------------------------------------------
def fig2_cache_conflict():
    fig, ax = plt.subplots(figsize=(7.6, 4.2))
    ax.set_xlim(0, 12); ax.set_ylim(0, 7); ax.axis("off")

    # W matrix (streaming) - left
    ax.add_patch(Rectangle((0.4, 1.0), 2.4, 5.0, fc="#E8F0FE", ec="#1F4E79", lw=1.2))
    ax.text(1.6, 6.3, r"$W \in \mathbb{R}^{M \times K}$", ha="center", fontsize=11,
            fontweight="bold")
    ax.text(1.6, 6.0, "(streaming, read-once)", ha="center", fontsize=9, style="italic")
    for i, y in enumerate(np.linspace(1.4, 5.6, 8)):
        ax.add_patch(Rectangle((0.5, y-0.15), 2.2, 0.25,
                                fc="#A8C5E8" if i == 4 else "#D6E4F5", ec="#1F4E79", lw=0.4))
    ax.text(1.6, 0.6, "row $i$ → 256 cache lines\nrow $i{+}1$ overwrites row $i$",
            ha="center", fontsize=8.5)

    # x vector (temporal) - middle-left of cache
    ax.add_patch(Rectangle((3.4, 2.5), 0.6, 2.5, fc="#FDF2E9", ec="#C0392B", lw=1.2))
    ax.text(3.7, 5.3, r"$x \in \mathbb{R}^K$", ha="center", fontsize=11, fontweight="bold")
    ax.text(3.7, 5.0, "(reused $M$×)", ha="center", fontsize=9, style="italic")
    for y in np.linspace(2.65, 4.85, 8):
        ax.add_patch(Rectangle((3.45, y-0.1), 0.5, 0.18,
                                fc="#F5C6A5", ec="#C0392B", lw=0.4))

    # Direct-mapped cache - middle
    ax.add_patch(Rectangle((5.0, 1.0), 2.4, 5.0, fc="#FFF9E5", ec="#7F6000", lw=1.4))
    ax.text(6.2, 6.3, "Direct-Mapped\nD-Cache", ha="center", fontsize=10.5,
            fontweight="bold")
    ax.text(6.2, 5.85, "index = addr[10:2]", ha="center", fontsize=8.5,
            family="monospace")
    for i, y in enumerate(np.linspace(1.4, 5.4, 10)):
        ax.add_patch(Rectangle((5.15, y-0.13), 2.1, 0.22,
                                fc="#FFE699", ec="#7F6000", lw=0.4))
    ax.text(6.2, 0.6, "K=256 → both W rows and x\nmap to identical index range",
            ha="center", fontsize=8.5)

    # Eviction cycle - right
    ax.add_patch(FancyBboxPatch((8.0, 1.4), 3.7, 4.8, boxstyle="round,pad=0.05",
                                 fc="#FDEDEC", ec="#922B21", lw=1.2))
    ax.text(9.85, 5.85, "Conflict Miss Cycle", ha="center", fontsize=10.5,
            fontweight="bold", color="#922B21")
    cycle_text = (
        "1. Load W[i] → fills cache\n\n"
        "2. Compute y[i] += W[i]·x\n      ↳ x evicted (slot reused)\n\n"
        "3. Reload x → evicts W[i]\n\n"
        "4. Load W[i+1] → evicts x\n\n"
        "Hit rate ≈ 0   (provably)\n"
        "Every tag compare wastes\n"
        "0.5–1.0 pJ × 2.6M / sentence"
    )
    ax.text(8.2, 5.4, cycle_text, fontsize=8.7, va="top", family="DejaVu Sans")

    # Arrows from W and x into cache
    ax.annotate("", xy=(5.0, 4.0), xytext=(2.85, 4.0),
                arrowprops=dict(arrowstyle="->", lw=1.2, color="#1F4E79"))
    ax.annotate("", xy=(5.0, 3.5), xytext=(4.0, 3.5),
                arrowprops=dict(arrowstyle="->", lw=1.2, color="#C0392B"))
    ax.annotate("", xy=(8.0, 3.7), xytext=(7.4, 3.7),
                arrowprops=dict(arrowstyle="->", lw=1.4, color="#922B21"))

    fig.suptitle("Fig. 2.  Cache access pattern and direct-mapped conflict-miss mechanism.",
                 fontsize=10, y=0.02)
    save(fig, "fig2_cache_conflict")

# ----------------------------------------------------------------------
# Fig 3: System Architecture with Bypass Path
# ----------------------------------------------------------------------
def fig3_system_arch():
    fig, ax = plt.subplots(figsize=(7.8, 4.6))
    ax.set_xlim(0, 14); ax.set_ylim(0, 8); ax.axis("off")

    def box(x, y, w, h, label, fc="#EEF2F7", ec="#333", fontsize=10, bold=True, sub=None):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.05",
                                     fc=fc, ec=ec, lw=1.2))
        ax.text(x+w/2, y+h/2 + (0.18 if sub else 0), label,
                ha="center", va="center", fontsize=fontsize,
                fontweight="bold" if bold else "normal")
        if sub:
            ax.text(x+w/2, y+h/2 - 0.28, sub, ha="center", va="center",
                    fontsize=8.5, style="italic", color="#444")

    # CPU
    box(0.5, 5.5, 2.3, 1.5, "RV32IM Core", fc="#D6E4F5", sub="single-cycle")
    # D-Cache
    box(3.6, 5.5, 2.3, 1.5, "D-Cache", fc="#FFE699", sub="direct-mapped")
    # DMEM
    box(7.0, 5.5, 2.3, 1.5, "DMEM (16MB)", fc="#F5CBA7", sub="40 ns ext.")
    # GEMV accelerator
    box(0.5, 2.5, 2.3, 1.5, "GEMV Accel.", fc="#D5F5E3", sub="8-way MAC")
    # DMA
    box(3.6, 2.5, 2.3, 1.5, "DMA Ctrl.", fc="#D5F5E3", sub="addr decoder")
    # SPM
    box(7.0, 2.5, 2.3, 1.5, "SPM (128KB)", fc="#FADBD8", sub="weight + KV")
    # Optional Stage-5 peripherals
    box(10.6, 5.5, 3.0, 1.5, "Softmax / LayerNorm",
        fc="#E8DAEF", sub="MMIO (Stage 5)")
    box(10.6, 2.5, 3.0, 1.5, "KV Cache Mgr.",
        fc="#FADBD8", sub="write-once-read-many")

    # Existing CPU<->cache<->DMEM path (black)
    ax.annotate("", xy=(3.6, 6.25), xytext=(2.8, 6.25),
                arrowprops=dict(arrowstyle="<->", lw=1.4, color="black"))
    ax.annotate("", xy=(7.0, 6.25), xytext=(5.9, 6.25),
                arrowprops=dict(arrowstyle="<->", lw=1.4, color="black"))

    # GEMV -> DMA
    ax.annotate("", xy=(3.6, 3.25), xytext=(2.8, 3.25),
                arrowprops=dict(arrowstyle="<->", lw=1.4, color="black"))

    # DMA -> D-Cache (legacy path) — DMEM-range addresses
    arrow_legacy = FancyArrowPatch((4.75, 4.0), (4.75, 5.5),
                                    arrowstyle="<->", lw=1.4, color="#555",
                                    mutation_scale=12)
    ax.add_patch(arrow_legacy)
    ax.text(5.0, 4.75, "DMEM-range\n(legacy path)", fontsize=8, color="#555")

    # DMA -> SPM (BYPASS path) — red dashed
    arrow_bypass = FancyArrowPatch((5.9, 3.25), (7.0, 3.25),
                                    arrowstyle="<->", lw=2.2, color="#C0392B",
                                    linestyle="--", mutation_scale=15)
    ax.add_patch(arrow_bypass)
    ax.text(6.45, 3.55, "BYPASS", fontsize=9, color="#C0392B",
            fontweight="bold", ha="center")

    # SPM <-> KV Cache Mgr
    ax.annotate("", xy=(10.6, 3.25), xytext=(9.3, 3.25),
                arrowprops=dict(arrowstyle="<->", lw=1.4, color="black"))

    # Highlight bypass region with red dashed box
    ax.add_patch(Rectangle((3.4, 2.2), 6.2, 2.1, fill=False,
                            ec="#C0392B", lw=1.6, ls=":"))
    ax.text(6.5, 1.95, "Address-based routing in GEMV DMA interface",
            ha="center", fontsize=9, color="#C0392B", style="italic")

    # Legend
    leg_x, leg_y = 0.5, 0.5
    ax.add_patch(Rectangle((leg_x, leg_y), 0.4, 0.18, fc="#555"))
    ax.text(leg_x+0.5, leg_y+0.09, "existing path (cache → DMEM)", va="center", fontsize=8)
    ax.plot([leg_x+5.5, leg_x+5.9], [leg_y+0.09, leg_y+0.09],
            color="#C0392B", lw=2.2, ls="--")
    ax.text(leg_x+6.0, leg_y+0.09, "new bypass path (this work)",
            va="center", fontsize=8, color="#C0392B")

    fig.suptitle("Fig. 3.  System architecture. Red dashed path is the proposed cache-bypass introduced in Stage 4.",
                 fontsize=10, y=0.02)
    save(fig, "fig3_system_arch")

# ----------------------------------------------------------------------
# Fig 4: SPM 128KB Memory Map
# ----------------------------------------------------------------------
def fig4_spm_map():
    fig, (ax, ax2) = plt.subplots(1, 2, figsize=(7.6, 4.2),
                                   gridspec_kw={"width_ratios": [1, 1.2]})

    # Left: stacked memory map
    total = 128
    weights = 46
    kv = 80
    pad = total - weights - kv  # 2KB padding/scratch

    base_y = 0.5
    h_w = weights * 0.04
    h_kv = kv * 0.04
    h_pad = pad * 0.04
    x0, w = 0.3, 1.4

    ax.add_patch(Rectangle((x0, base_y), w, h_kv, fc="#FADBD8", ec="#922B21", lw=1.3))
    ax.text(x0+w/2, base_y+h_kv/2, "KV Cache\n~80 KB",
            ha="center", va="center", fontsize=11, fontweight="bold")
    ax.add_patch(Rectangle((x0, base_y+h_kv), w, h_w, fc="#D5F5E3", ec="#1E8449", lw=1.3))
    ax.text(x0+w/2, base_y+h_kv+h_w/2, "Weight Tile\n~46 KB",
            ha="center", va="center", fontsize=11, fontweight="bold")
    ax.add_patch(Rectangle((x0, base_y+h_kv+h_w), w, h_pad, fc="#EAEDED",
                            ec="#555", lw=0.8))
    ax.text(x0+w/2, base_y+h_kv+h_w+h_pad/2, "scratch ~2KB",
            ha="center", va="center", fontsize=8, style="italic")

    # address labels
    ax.text(x0-0.1, base_y, "0x00000", ha="right", va="center",
            fontsize=8.5, family="monospace")
    ax.text(x0-0.1, base_y+h_kv, "0x14000", ha="right", va="center",
            fontsize=8.5, family="monospace")
    ax.text(x0-0.1, base_y+h_kv+h_w, "0x1F800", ha="right", va="center",
            fontsize=8.5, family="monospace")
    ax.text(x0-0.1, base_y+total*0.04, "0x20000", ha="right", va="center",
            fontsize=8.5, family="monospace")

    ax.text(x0+w/2, base_y+total*0.04+0.25, "SPM 128 KB",
            ha="center", fontsize=11, fontweight="bold")
    ax.set_xlim(-0.2, 2.0); ax.set_ylim(0, base_y+total*0.04+0.6)
    ax.axis("off")
    ax.set_title("(a) SPM partition", fontsize=10, pad=8)

    # Right: KV cache sizing math
    ax2.axis("off")
    text = (
        r"$\bf{KV\ cache\ sizing\ (Multi30K\ Transformer)}$" + "\n"
        "──────────────────────────────────\n"
        "Parameters:\n"
        "  d$_{model}$ = 128       (4 heads × 32)\n"
        "  L          = 2 decoder layers\n"
        "  T$_{max}$  = 50 tokens (Multi30K)\n"
        "  bytes      = 2  (FP16)\n\n"
        r"Per-layer  K size = T$_{max}\!\times$d$_{model}\!\times$2 = 12.8 KB"+"\n"
        r"Per-layer  V size = T$_{max}\!\times$d$_{model}\!\times$2 = 12.8 KB"+"\n\n"
        r"Total KV  = 2(K+V) $\times$ L = 2$\times$25.6 $\times$ 2 = 51.2 KB"+"\n\n"
        "Reserved budget (incl. encoder ctx & double buffer):\n"
        r"$\rightarrow$ 80 KB  (1.56× headroom)"+"\n\n"
        r"$\bf{Weight\ tile\ buffer}$" + "\n"
        "──────────────────────────────────\n"
        "Largest GEMV tile: 512 × 64 × 2 B  = 64 KB\n"
        "Streaming double-buffer:    32 + 32 = 46 KB tile"
    )
    ax2.text(0.0, 0.98, text, ha="left", va="top", fontsize=9.2,
             bbox=dict(boxstyle="round,pad=0.5", fc="#FBFBFB", ec="#888"))
    ax2.set_title("(b) Sizing analysis", fontsize=10, pad=8, loc="left")

    fig.suptitle("Fig. 4.  SPM 128 KB partition with KV-cache sizing.",
                 fontsize=10, y=0.02)
    save(fig, "fig4_spm_map")

# ----------------------------------------------------------------------
# Fig 5: Timing — 4-cycle vs 1-cycle access
# ----------------------------------------------------------------------
def fig5_timing():
    fig, ax = plt.subplots(figsize=(8.4, 3.8))

    # Cycle grid: each cycle = 1.4 wide, starting at x=2.0
    cyc_w = 1.4
    x_start = 2.0
    n_cyc = 6
    ax.set_xlim(0, x_start + n_cyc*cyc_w + 0.4); ax.set_ylim(-0.6, 4.6)
    ax.axis("off")

    # Cycle vertical guides + T labels
    for c in range(n_cyc + 1):
        x = x_start + c * cyc_w
        ax.plot([x, x], [-0.2, 4.2], color="#DDD", lw=0.6, ls=":")
        ax.text(x, -0.55, f"T{c}", ha="center", fontsize=9, color="#555")

    # CLK waveform
    clk_y = 3.7
    xs = np.linspace(x_start, x_start + n_cyc*cyc_w, 400)
    clk = 0.18 * np.sign(np.sin(2*np.pi*(xs - x_start)/cyc_w)) + clk_y
    ax.plot(xs, clk, color="black", lw=1.1)
    ax.text(x_start - 0.15, clk_y, "CLK", ha="right", va="center", fontsize=10)

    def stage(x0, w, y, label, color, ec="#222"):
        ax.add_patch(FancyBboxPatch((x0, y-0.30), w, 0.60, boxstyle="round,pad=0.02",
                                     fc=color, ec=ec, lw=1.0))
        ax.text(x0+w/2, y, label, ha="center", va="center",
                fontsize=9.5, fontweight="bold")

    # Cache path: 4 cycles, separated boxes (small gap so labels never collide)
    cy = 2.4
    ax.text(x_start - 0.15, cy, "Cache\npath", ha="right", va="center",
            fontsize=10, color="#7F6000")
    gap = 0.05
    bw = cyc_w - gap
    stage(x_start + 0*cyc_w + gap/2, bw, cy, "Tag rd",   "#FCE4A6")
    stage(x_start + 1*cyc_w + gap/2, bw, cy, "Tag cmp",  "#FCE4A6")
    stage(x_start + 2*cyc_w + gap/2, bw, cy, "Hit/Miss", "#FCE4A6")
    stage(x_start + 3*cyc_w + gap/2, bw, cy, "Data ret", "#FCE4A6")
    # 4-cycle bracket below cache path
    ax.annotate("", xy=(x_start + 4*cyc_w, cy-0.55), xytext=(x_start, cy-0.55),
                arrowprops=dict(arrowstyle="<->", color="#7F6000", lw=1.4))
    ax.text(x_start + 2*cyc_w, cy-0.85,
            "4 cycles  (every access wastes tag energy)",
            ha="center", fontsize=9.5, color="#7F6000")

    # Bypass path: 1 cycle
    by = 0.7
    ax.text(x_start - 0.15, by, "Bypass\npath", ha="right", va="center",
            fontsize=10, color="#922B21")
    stage(x_start + gap/2, bw, by, "SPM read", "#F5B7B1", ec="#922B21")
    ax.annotate("", xy=(x_start + cyc_w, by-0.55), xytext=(x_start, by-0.55),
                arrowprops=dict(arrowstyle="<->", color="#922B21", lw=1.4))
    ax.text(x_start + 0.5*cyc_w, by-0.85,
            "1 cycle  (no tag, no compare)",
            ha="center", fontsize=9.5, color="#922B21")

    # Saving banner — placed in clear space ABOVE the cache path
    saving_y = 4.25
    ax.add_patch(FancyBboxPatch(
        (x_start + 0.1, saving_y - 0.22),
        4*cyc_w - 0.2, 0.44,
        boxstyle="round,pad=0.02",
        fc="#E8F8EC", ec="#1E8449", lw=1.2))
    ax.text(x_start + 2*cyc_w, saving_y,
            "Saving:  3-cycle latency  +  ~2.6 M tag-compares eliminated per sentence",
            ha="center", va="center", fontsize=9.5,
            color="#196F3D", fontweight="bold")

    fig.suptitle("Fig. 5.  GEMV weight-read timing: legacy cache path (4 cycles) vs proposed bypass (1 cycle).",
                 fontsize=10, y=0.02)
    save(fig, "fig5_timing")

# ----------------------------------------------------------------------
# Fig 6: Staged Optimization Pipeline
# ----------------------------------------------------------------------
def fig6_stages():
    fig, ax = plt.subplots(figsize=(8.0, 3.2))
    ax.set_xlim(0, 18); ax.set_ylim(0, 4); ax.axis("off")

    stages = [
        ("Stage 0",  "LSTM\nbaseline\n(fix bug)",     "#EAF2F8"),
        ("Stage 1",  "Transformer\nSW migration",     "#EAF2F8"),
        ("Stage 2",  "GEMV\nintegration",             "#EAF2F8"),
        ("Stage 3",  "SPM 128KB\n+DMA +KV",           "#EAF2F8"),
        ("Stage 4",  "Cache\nBYPASS path",            "#FADBD8"),  # core
        ("Stage 5*", "Softmax /\nLayerNorm HW",       "#EBDEF0"),
    ]
    w = 2.6; gap = 0.3; x = 0.2
    for i, (tag, lbl, fc) in enumerate(stages):
        is_core = (i == 4)
        ax.add_patch(FancyBboxPatch((x, 1.0), w, 2.0, boxstyle="round,pad=0.05",
                                     fc=fc, ec="#922B21" if is_core else "#333",
                                     lw=2.0 if is_core else 1.0))
        ax.text(x+w/2, 2.55, tag, ha="center", fontsize=10, fontweight="bold",
                color="#922B21" if is_core else "black")
        ax.text(x+w/2, 1.7, lbl, ha="center", fontsize=9.2)
        if i < len(stages) - 1:
            ax.annotate("", xy=(x+w+gap, 2.0), xytext=(x+w, 2.0),
                        arrowprops=dict(arrowstyle="->", lw=1.4, color="#444"))
        x += w + gap

    ax.text(0.2, 0.5, "*Stretch goal", fontsize=8.5, color="#555", style="italic")
    ax.text(13.4, 3.4, "Core contribution",
            fontsize=9, color="#922B21", fontweight="bold")
    ax.annotate("", xy=(13.4, 3.05), xytext=(13.4, 3.3),
                arrowprops=dict(arrowstyle="->", color="#922B21", lw=1.5))

    fig.suptitle("Fig. 6.  Staged co-design pipeline. Each stage adds exactly one optimization for clean ablation.",
                 fontsize=10, y=0.02)
    save(fig, "fig6_stages")

# ----------------------------------------------------------------------
# Fig 8: Expected Results (Table II)
# ----------------------------------------------------------------------
def fig8_expected():
    stages = ["S0\nLSTM", "S1\nTF SW", "S2\n+GEMV", "S3\n+SPM/KV",
              "S4\n+Bypass", "S5*\n+SF/LN"]
    cpi      = [1.0, 3.0, 1.6, 1.0, 0.7, 0.55]   # rel. to S1
    mem_cost = [1.0, 1.0, 0.9, 0.30, 0.22, 0.20] # rel. to S1
    tag_eng  = [1.0, 1.0, 1.0, 1.0, 0.0, 0.0]    # rel. to S0

    fig, axes = plt.subplots(1, 3, figsize=(9.0, 3.0), sharey=False)
    x = np.arange(len(stages))

    def bar(ax, vals, title, ylabel, color, baseline_idx=1, highlight_idx=4):
        bars = ax.bar(x, vals, color=color, ec="#333", lw=0.8)
        bars[highlight_idx].set_edgecolor("#922B21")
        bars[highlight_idx].set_linewidth(2.0)
        ax.set_xticks(x); ax.set_xticklabels(stages, fontsize=8.5)
        ax.set_title(title, fontsize=10, pad=6)
        ax.set_ylabel(ylabel, fontsize=9)
        ax.axhline(1.0, color="#888", lw=0.6, ls="--")
        ax.grid(axis="y", lw=0.3, ls=":", color="#CCC")
        ax.set_axisbelow(True)
        for i, v in enumerate(vals):
            ax.text(i, v+0.02, f"{v:.2f}", ha="center", fontsize=7.5)

    bar(axes[0], cpi,      "(a) CPI (rel. to S1)",
        "lower is better", "#5B9BD5")
    bar(axes[1], mem_cost, "(b) Mem. access cost (rel. to S1)",
        "lower is better", "#ED7D31")
    bar(axes[2], tag_eng,  "(c) Tag energy (rel. to S0)",
        "lower is better", "#A5A5A5")

    # Annotation on Stage 4 in plot (c) — the cliff
    axes[2].annotate("0  (bypass\neliminates tag)",
                     xy=(4, 0.05), xytext=(2.8, 0.55),
                     arrowprops=dict(arrowstyle="->", color="#922B21"),
                     fontsize=9, color="#922B21", fontweight="bold")

    fig.suptitle("Fig. 8.  Expected per-stage metrics (Table II). Stage 4 is the core contribution (red border).",
                 fontsize=10, y=0.02)
    fig.tight_layout(rect=[0, 0.04, 1, 1])
    save(fig, "fig8_expected_results")

# ----------------------------------------------------------------------
if __name__ == "__main__":
    print("Generating figures into:", OUT)
    fig1_power_breakdown()
    fig2_cache_conflict()
    fig3_system_arch()
    fig4_spm_map()
    fig5_timing()
    fig6_stages()
    fig8_expected()
    print("Done.")
