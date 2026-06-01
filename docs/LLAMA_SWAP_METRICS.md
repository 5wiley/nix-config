# llama-swap Metrics & Dashboard Queries

Operational metrics for llama-swap on nas-01, sourced from two pipelines:

1. **Loki recording rules** (`llama:*`) — LogQL queries evaluated every 1m, remote-written to Mimir
2. **Textfile collector** (`llamacpp:*`) — scraped from llama-server `/metrics` endpoint, has `model` label

## Metric Sources

### Loki Recording Rules

Defined in `clubcotton/services/loki/rules/llama-swap.yml`. Configured via the `rulesDir` option in the Loki module. The ruler evaluates LogQL on a 1m interval and remote-writes results to Mimir.

These metrics are **sparse** — they only produce datapoints when matching log lines appear in the evaluation window. Use `or vector(0)` in dashboard panels to show zero instead of gaps.

### Textfile Collector

The existing Prometheus textfile collector scrapes llama-server's `/metrics` endpoint every minute. These metrics have an `instance` and `model` label.

## Available Metrics

### From Loki Recording Rules

| Metric | Type | Description |
|--------|------|-------------|
| `llama:kv_cache_used_mib` | gauge | KV cache memory usage in MiB |
| `llama:kv_cache_prompts` | gauge | Number of cached prompts |
| `llama:prompt_tokens` | gauge | Prompt size in tokens |
| `llama:prompt_batch_tokens` | gauge | Batch token count per prompt eval |
| `llama:kv_cache_errors:rate5m` | counter | KV cache full events (5m window) |
| `llama:context_exceeded_errors:rate5m` | counter | Context overflow errors (5m window) |
| `llama:model_exits:rate5m` | counter | Model crash/exit events (5m window) |
| `llama:model_unloads:rate5m` | counter | Model TTL unload events (5m window) |
| `llama:prompt_cache_hits:rate5m` | counter | Prompt evals with batch < 512 tokens (5m window) |
| `llama:prompt_full_evals:rate5m` | counter | Prompt evals with batch >= 512 tokens (5m window) |
| `llama:model_unloads_by_model:rate5m` | counter | Unloads by model name (5m window, has `model` label) |
| `llama:prompt_tokens_bucket` | histogram | Cumulative prompt size distribution (le: 8192, 32768, 65536, 131072, +Inf) |

### From Textfile Collector

All have labels: `instance="nas-01"`, `job="node"`, `model="<name>"`.

| Metric | Type | Description |
|--------|------|-------------|
| `llamacpp:prompt_tokens_seconds` | gauge | Prompt eval speed (tok/s, last request) |
| `llamacpp:predicted_tokens_seconds` | gauge | Generation speed (tok/s, last request) |
| `llamacpp:n_tokens_max` | gauge | Max context tokens ever used |
| `llamacpp:prompt_tokens_total` | counter | Total prompt tokens processed |
| `llamacpp:tokens_predicted_total` | counter | Total tokens generated |
| `llamacpp:prompt_seconds_total` | counter | Total time spent on prompt eval (seconds) |
| `llamacpp:tokens_predicted_seconds_total` | counter | Total time spent on generation (seconds) |
| `llamacpp:n_decode_total` | counter | Total decode calls |
| `llamacpp:n_busy_slots_per_decode` | gauge | Busy slots per decode |
| `llamacpp:requests_processing` | gauge | Current requests in flight |
| `llamacpp:requests_deferred` | gauge | Deferred requests |

## Dashboard PromQL Queries

These queries replicate the output of `scripts/llama-perf.sh`. Use `$__range` in Grafana for the dashboard time range, or substitute a fixed range like `[24h]`.

### KV Cache

**Stat panels:**

```promql
# Min usage (MiB)
min_over_time(llama:kv_cache_used_mib[$__range])

# Avg usage (MiB)
avg_over_time(llama:kv_cache_used_mib[$__range])

# Max usage (MiB)
max_over_time(llama:kv_cache_used_mib[$__range])

# Max usage % (cache limit is 8192 MiB)
max_over_time(llama:kv_cache_used_mib[$__range]) / 8192 * 100

# Avg cached prompts
avg_over_time(llama:kv_cache_prompts[$__range])

# Max cached prompts
max_over_time(llama:kv_cache_prompts[$__range])
```

**Time series panels:**

```promql
# KV cache usage over time
llama:kv_cache_used_mib

# Cached prompt count over time
llama:kv_cache_prompts
```

### KV Cache Health

**Stat panels:**

```promql
# KV cache full events (total in range)
sum_over_time(llama:kv_cache_errors:rate5m[$__range]) or vector(0)

# Context exceeded errors (total in range)
sum_over_time(llama:context_exceeded_errors:rate5m[$__range]) or vector(0)

# Model exit errors (total in range)
sum_over_time(llama:model_exits:rate5m[$__range]) or vector(0)
```

**Time series panels:**

```promql
# Error rates over time
llama:kv_cache_errors:rate5m
llama:context_exceeded_errors:rate5m
llama:model_exits:rate5m
```

### Context Window Usage

**Stat panels:**

```promql
# Max tokens ever used (from /metrics endpoint)
llamacpp:n_tokens_max

# Min prompt size (tokens)
min_over_time(llama:prompt_tokens[$__range])

# Avg prompt size (tokens)
avg_over_time(llama:prompt_tokens[$__range])

# Max prompt size (tokens)
max_over_time(llama:prompt_tokens[$__range])

# Avg prompt size as % of slot (context is 262144 tokens)
avg_over_time(llama:prompt_tokens[$__range]) / 262144 * 100

# Max prompt size as % of slot
max_over_time(llama:prompt_tokens[$__range]) / 262144 * 100
```

**Time series panel:**

```promql
# Prompt size over time
llama:prompt_tokens
```

**Prompt size distribution (histogram panel or bar gauge):**

```promql
# p50 prompt size
histogram_quantile(0.5, llama:prompt_tokens_bucket)

# p90 prompt size
histogram_quantile(0.9, llama:prompt_tokens_bucket)

# p95 prompt size
histogram_quantile(0.95, llama:prompt_tokens_bucket)

# Raw bucket counts (for heatmap or bar chart)
llama:prompt_tokens_bucket
```

### Throughput

**Stat panels (current values):**

```promql
# Current generation speed (tok/s)
llamacpp:predicted_tokens_seconds

# Current prompt eval speed (tok/s)
llamacpp:prompt_tokens_seconds
```

**Stat panels (range aggregates):**

```promql
# Min/Avg/Max generation speed over range
min_over_time(llamacpp:predicted_tokens_seconds[$__range])
avg_over_time(llamacpp:predicted_tokens_seconds[$__range])
max_over_time(llamacpp:predicted_tokens_seconds[$__range])

# Min/Avg/Max prompt eval speed over range
min_over_time(llamacpp:prompt_tokens_seconds[$__range])
avg_over_time(llamacpp:prompt_tokens_seconds[$__range])
max_over_time(llamacpp:prompt_tokens_seconds[$__range])

# Average throughput from counters (more accurate over long ranges)
rate(llamacpp:tokens_predicted_total[$__range]) / rate(llamacpp:tokens_predicted_seconds_total[$__range])
rate(llamacpp:prompt_tokens_total[$__range]) / rate(llamacpp:prompt_seconds_total[$__range])
```

**Time series panels:**

```promql
# Generation speed over time
llamacpp:predicted_tokens_seconds

# Prompt eval speed over time
llamacpp:prompt_tokens_seconds
```

### Cache Efficiency

**Stat panels:**

```promql
# Cache hit rate %
llama:prompt_cache_hits:rate5m
  / (llama:prompt_cache_hits:rate5m + llama:prompt_full_evals:rate5m)
  * 100

# Cache hits (batch < 512 tokens)
llama:prompt_cache_hits:rate5m

# Full re-evals (batch >= 512 tokens)
llama:prompt_full_evals:rate5m

# Total prompt evals in range
sum_over_time(llama:prompt_cache_hits:rate5m[$__range])
  + sum_over_time(llama:prompt_full_evals:rate5m[$__range])

# Avg batch tokens per prompt
avg_over_time(llama:prompt_batch_tokens[$__range])
```

**Time series panels:**

```promql
# Cache hits vs full evals over time
llama:prompt_cache_hits:rate5m
llama:prompt_full_evals:rate5m

# Batch token size over time
llama:prompt_batch_tokens
```

### Model Management

**Stat panels:**

```promql
# Total unloads in range
sum_over_time(llama:model_unloads:rate5m[$__range]) or vector(0)

# Unloads by model (total in range)
sum by (model) (sum_over_time(llama:model_unloads_by_model:rate5m[$__range]))
```

**Time series / table panels:**

```promql
# Unload events over time
llama:model_unloads:rate5m

# Unloads by model over time
llama:model_unloads_by_model:rate5m
```

## Verification

After deploying, verify the recording rules are loaded and healthy:

```bash
# Check ruler status
curl http://nas-01.lan:3100/ruler/ring

# List loaded rules
curl http://nas-01.lan:3100/loki/api/v1/rules

# Check rule health (all should show health: "ok")
curl -s http://nas-01.lan:3100/prometheus/api/v1/rules \
  | jq '.data.groups[0].rules[] | {name: .name, health: .health, lastError: .lastError}'

# Query a metric in Mimir
curl -s 'http://nas-01.lan:9009/prometheus/api/v1/query?query=llama:kv_cache_used_mib'
```

## CLI Alternative

For a quick terminal report without Grafana, use:

```bash
just llama-perf                           # Last 24h, all models
just llama-perf --since=7d               # Last 7 days
just llama-perf --model=qwen3.5-35b-a3b-coding
```

## Files

- `clubcotton/services/loki/rules/llama-swap.yml` — Recording rule definitions
- `clubcotton/services/loki/default.nix` — Loki module with `rulesDir` option and ruler config
- `scripts/llama-perf.sh` — CLI performance report (queries Loki directly)
