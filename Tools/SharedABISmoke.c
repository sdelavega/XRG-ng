/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Stephen de la Vega. */
#include "xrg_shared.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    assert(xrg_shared_abi_version() == 1);
    void *history = xrg_history_create(3);
    assert(history);
    for (int i = 1; i <= 4; i++) assert(xrg_history_append(history, i) == 0);
    assert(xrg_history_append(history, NAN) == -1);
    double values[4] = {99, 99, 99, 99};
    assert(xrg_history_copy(history, values, 2) == -1);
    assert(values[0] == 99 && values[3] == 99);
    assert(xrg_history_copy(history, values, 3) == 3);
    assert(values[0] == 2 && values[1] == 3 && values[2] == 4 && values[3] == 99);
    xrg_history_free(history);
    void *rate = xrg_rate_create();
    uint64_t delta = 99;
    assert(xrg_rate_sample(rate, 1, 10, 1, &delta) == 0 && delta == 0);
    assert(xrg_rate_sample(rate, 1, 510, 3, &delta) == 250 && delta == 500);
    xrg_rate_free(rate);
    assert(xrg_theme_count() == 6);
    double colors[28];
    assert(xrg_theme_colors(4, colors, 28) == 28);
    uint8_t name[64];
    assert(xrg_theme_name(4, name, 64) == 5);
    puts("C_ABI_SMOKE_OK");
    return 0;
}
