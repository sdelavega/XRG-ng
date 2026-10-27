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
void *xrg_history_create(uint32_t capacity);
void xrg_history_free(void *handle);
int32_t xrg_history_append(void *handle, double value);
int32_t xrg_history_copy(void *handle, double *output, uint32_t capacity);
void *xrg_rate_create(void);
void xrg_rate_free(void *handle);
uint32_t xrg_rate_sample(void *handle, uint32_t key, uint64_t counter, double time, uint64_t *delta);
uint32_t xrg_theme_count(void);
int32_t xrg_theme_name(uint32_t index, uint8_t *output, uint32_t capacity);
/* Seven RGBA colors (28 doubles) in background, graphBG, FG1, FG2, FG3, border, text order. */
int32_t xrg_theme_colors(uint32_t index, double *output, uint32_t capacity);
int32_t xrg_metrics_parse(const uint8_t *bytes, uint32_t length, uint64_t *tokens, double *cost);
int32_t xrg_codex_record_parse(const uint8_t *bytes, uint32_t length, uint64_t *tokens);
#ifdef __cplusplus
}
#endif
#endif
