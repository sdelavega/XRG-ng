/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Stephen de la Vega. */
#include "xrg_shared.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
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
    const char *record = "{\"message\":{\"id\":\"m1\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}}";
    uint64_t input = 99, output = 99, total = 99;
    assert(xrg_provider_usage_parse((const uint8_t *)record, strlen(record), 0,
        &input, &output, &total, name, 1) == -2);
    assert(input == 99 && output == 99 && total == 99);
    assert(xrg_provider_usage_parse((const uint8_t *)record, strlen(record), 0,
        &input, &output, &total, name, sizeof(name)) == 2);
    assert(input == 7 && output == 3 && total == 10 && name[0] == 'm' && name[1] == '1');
    const char *models = "{\"models\":[{\"name\":\"test\"}]}";
    assert(xrg_model_names_parse((const uint8_t *)models, strlen(models), name, sizeof(name)) == 4);
    const char *metrics = "claude_code_token_usage_total{type=\"input\"} 0\n";
    double cost = 99;
    assert(xrg_metrics_sample_parse((const uint8_t *)metrics, strlen(metrics), &total, &cost) == 1 && total == 0);
    puts("C_ABI_SMOKE_OK");
    return 0;
}
