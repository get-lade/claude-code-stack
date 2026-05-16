# Hardware Sizing for Tier 5 (Ollama)

Tier 5 runs Ollama models locally on the laptop. Different laptop classes support different models.

## the maintainer's current: MacBook Air M-series

Without knowing the exact spec, three scenarios:

### Air with 8GB unified memory
- **Supported:** Llama 3.2 3B, Qwen 2.5 3B, small classification models.
- **Not supported:** Anything 13B+ (will swap, very slow).
- **Recommendation:** Tier 5 is marginally useful here. Local-ops can do trivial classification only. the maintainer would need to upgrade for meaningful local capability.

### Air with 16GB unified memory
- **Supported:** Up to Qwen 2.5 7B, Llama 3.1 8B, comfortably. 13B with some swap.
- **Not supported:** 32B+ models.
- **Recommendation:** Useful for trivial-medium local tasks. Llama 3.1 8B as primary; Llama 3.2 3B for fast classification.

### Air with 24GB or higher unified memory
- **Supported:** 13B comfortably, 32B with care (Qwen 2.5 Coder 32B fits).
- **Not supported:** 70B (will swap heavily).
- **Recommendation:** Real Tier 5 capability. Qwen 2.5 Coder 32B for code, Llama 3.1 8B for general.

## Recommended: MacBook Pro M-series (the maintainer's stated potential upgrade)

### Pro 14" or 16" with 36GB+ unified memory
- **Supported:** 70B with care (Llama 3.3 70B fits in unified memory but constrained).
- **Recommended setup:** Llama 3.3 70B as primary local reasoning, Qwen 2.5 Coder 32B for code, Llama 3.2 3B for classification.

### Pro 16" with 48GB+ unified memory
- **Sweet spot for Tier 5.** 70B comfortable, headroom for context.
- **Recommended setup:** Llama 3.3 70B primary, multiple loaded simultaneously possible.

### Pro 16" with 64GB+ unified memory
- **Overkill but future-proof.** Can run 70B with very large context, or 2 mid-size models concurrently.

## Recommendation matrix

| Use case | Min spec | Sweet spot |
|---|---|---|
| Tier 0-4 only (no Tier 5) | 8GB Air | 16GB Air |
| Tier 5, trivial local-ops only | 16GB Air | 24GB Air |
| Tier 5, meaningful local reasoning | 36GB Pro | 48GB Pro |
| Tier 5 + heavy parallel work | 48GB Pro | 64GB Pro |

## the maintainer's situation

Per the maintainer's stated plan: currently on MacBook Air; potentially upgrading to Pro.

**Recommendation:**
- If staying on current Air: install Tier 5 with Llama 3.2 3B only. Local-ops is limited to classification.
- If upgrading to Pro: target 36GB+ for genuine Tier 5 capability. 48GB if budget allows.

The 16" MacBook Pro with M-series Max chip + 48GB unified memory is the recommended target. Anything less and Tier 5 is a checkbox more than a capability.

## Update — the maintainer's actual machine (2026-05-16)

the maintainer's MacBook Air is an **M4 with 32GB unified memory**, 1TB storage. This lands
in the "24GB or higher" bracket — **real Tier 5 capability**. Installed model set:
- **Qwen 2.5 Coder 32B** — code (fits with care on 32GB)
- **Llama 3.1 8B** — general reasoning (local-ops default)
- **Llama 3.2 3B** — trivial classification

Llama 3.3 70B is **not** installed — it needs 36GB+ and would swap heavily. If the maintainer
upgrades to a 36GB+ Pro, add 70B via `ollama pull llama3.3:70b` and update
`agents/local-ops.md`.

## Disk space

Ollama models are large.
- Llama 3.2 3B: ~2GB
- Llama 3.1 8B: ~5GB
- Qwen 2.5 Coder 32B: ~20GB
- Llama 3.3 70B: ~42GB

Total for recommended Tier 5 setup: ~70GB on disk. Plan accordingly.

## Network requirements

Ollama runs locally — no network needed for inference. But:
- Initial model download requires bandwidth (~70GB total for full set).
- Model updates as new versions release.
- No telemetry leaves the machine (Ollama is privacy-preserving).
