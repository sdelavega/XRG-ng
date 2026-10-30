/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Stephen de la Vega. */
#ifndef XRG_SHARED_H
#define XRG_SHARED_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1. Buffers belong to the caller. Counts are elements, not bytes (except
 * UTF-8 inputs/names). No function writes beyond capacity. Status -1 means invalid
 * arguments; parse status 1 means no matching record. Handles are thread-confined,
 * must come from the matching create, and must be freed exactly once. NULL free is
 * allowed. History capacity is 1..86400; text input is limited to 8 MiB.
 * Histories start zero-filled; copy returns oldest-to-newest including that padding.
 * Rate output saturates at UINT32_MAX bytes/sec; first/reset samples return zero. */
uint32_t xrg_shared_abi_version(void);
/* Weather additions retain ABI v1. Station returns 4 uppercase ASCII bytes,
 * no NUL, or -1. Input <=64 bytes; capacity >=4; failures leave output untouched. */
int32_t xrg_metar_station(const uint8_t *bytes, uint32_t length, uint8_t *output, uint32_t capacity);
/* Latest matching METAR within reference-36h..reference+5min. Reference is UTC
 * Unix seconds, 0..253402300799. Input <=2 MiB, station <=64 bytes.
 * values[10]: observation Unix seconds, temperature C, dewpoint C, humidity %,
 * wind degrees (-1 variable), wind knots, gust knots, visibility statute miles,
 * pressure hPa, pressure inHg. Valid-value bits 0..8 correspond to values[1..9];
 * absent values are zero with their bit clear. Visibility qualifier bits:
 * 16 less-than, 17 greater-than, 18 greater-or-equal. Time is always present.
 * Returns raw UTF-8 byte count (<=8192, no NUL), -1 invalid/no recent report,
 * -2 raw capacity too small. All outputs remain untouched on failure. */
int32_t xrg_metar_latest_parse(const uint8_t *bytes, uint32_t length,
    const uint8_t *station, uint32_t station_length, int64_t reference,
    double *values, uint32_t capacity, uint32_t *flags, uint8_t *raw, uint32_t raw_capacity);
/* Dated METAR history, matching station and reference-36h..reference+5min.
 * Input <=2 MiB; <=2048 observations. JSON rows use the Rust Metar field names,
 * oldest first; first duplicate timestamp wins within a response. Returns JSON
 * byte count, -1 invalid/no matching reports, -2 short buffer; output untouched
 * on failure. No parsing or storage handle is retained. */
int32_t xrg_metar_history_parse(const uint8_t *bytes, uint32_t length,
    const uint8_t *station, uint32_t station_length, int64_t reference,
    uint8_t *output, uint32_t capacity);
/* 1: same device/inode, nondecreasing file size and tokens; otherwise 0.
 * Inventory additions/removals are boundaries handled by each scanner. */
int32_t xrg_log_file_continues(uint64_t old_device, uint64_t old_inode,
    uint64_t old_bytes, uint64_t old_tokens, uint64_t device, uint64_t inode,
    uint64_t bytes, uint64_t tokens);
void *xrg_history_create(uint32_t capacity);
void xrg_history_free(void *handle);
int32_t xrg_history_append(void *handle, double value);
int32_t xrg_history_copy(void *handle, double *output, uint32_t capacity);
void *xrg_rate_create(void);
void xrg_rate_free(void *handle);
uint32_t xrg_rate_sample(void *handle, uint32_t key, uint64_t counter, double time, uint64_t *delta);
/* Observed token deltas: thread-confined ledger; reset changes baselines only.
 * JSON request {provider,source,usage:{input,output,total}|null,models:{name:count}}.
 * Max 1 MiB input, provider 1..64 bytes, source <=4096, <=256 named models,
 * names 1..1024 UTF-8 bytes, no controls. JSON response {delta?:{usage,models}};
 * absent delta means baseline/no growth. Missing/invalid usage breaks continuity.
 * Returns response byte count, -1 invalid args, -2 short buffer. Failure leaves
 * output AND ledger unchanged, so callers can retry with a larger buffer. */
void *xrg_accounting_create(void);
void xrg_accounting_free(void *handle);
int32_t xrg_accounting_reset(void *handle);
int32_t xrg_accounting_sample(void *handle, const uint8_t *bytes, uint32_t length,
    uint8_t *output, uint32_t capacity);
uint32_t xrg_theme_count(void);
int32_t xrg_theme_name(uint32_t index, uint8_t *output, uint32_t capacity);
/* Seven RGBA colors (28 doubles) in background, graphBG, FG1, FG2, FG3, border, text order. */
int32_t xrg_theme_colors(uint32_t index, double *output, uint32_t capacity);
int32_t xrg_metrics_parse(const uint8_t *bytes, uint32_t length, uint64_t *tokens, double *cost);
/* Valid sample flags: 1 token, 2 cost; -1 invalid arguments. */
int32_t xrg_metrics_sample_parse(const uint8_t *bytes, uint32_t length, uint64_t *tokens, double *cost);
/* Same accepted cumulative records, with explicit input/output components when
 * consistent with total; otherwise both components are zero. 0 success, 1 ignored,
 * -1 invalid arguments. Outputs remain untouched on failure. No cache/reasoning
 * subfields are added again to the recorded input/output/total values. */
int32_t xrg_codex_usage_parse(const uint8_t *bytes, uint32_t length,
    uint64_t *input, uint64_t *output, uint64_t *total);
int32_t xrg_codex_record_parse(const uint8_t *bytes, uint32_t length, uint64_t *tokens);
/* Usage kind: 0 Claude record, 1 Gemini record, 2 Gemini session.
 * Returns identity UTF-8 byte count (no NUL), -1 invalid/nonmatching input, -2
 * insufficient identity capacity. All outputs remain untouched on failure. */
int32_t xrg_provider_usage_parse(const uint8_t *bytes, uint32_t length, uint32_t kind,
    uint64_t *input, uint64_t *output, uint64_t *total, uint8_t *identity, uint32_t capacity);
/* Additive ABI v1 details: kind as above. UTF-8 JSON (no NUL), <=512 KiB:
 * {"record":{input,output,total,identity,model?},"models":[same fields...]}
 * Counts are exact unsigned 64-bit JSON integers. At most 256 model rows;
 * names/identity <=1024 bytes; missing/invalid model names are unattributed.
 * Returns byte count, -1 invalid/nonmatching input, -2 insufficient capacity.
 * Output remains untouched on failure. Input <=8 MiB. */
int32_t xrg_provider_details_parse(const uint8_t *bytes, uint32_t length, uint32_t kind,
    uint8_t *output, uint32_t capacity);
/* Newline-delimited model names; returns byte count or -1. */
int32_t xrg_model_names_parse(const uint8_t *bytes, uint32_t length, uint8_t *output, uint32_t capacity);
#ifdef __cplusplus
}
#endif
#endif
