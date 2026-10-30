/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Stephen de la Vega. */
#include "xrg_shared.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    assert(xrg_shared_abi_version() == 1);
    assert(xrg_cpu_interval_valid(0, 300) == 1);
    assert(xrg_cpu_interval_valid(0, 300.001) == 0);
    assert(xrg_cpu_interval_valid(1, 1) == 0);
    assert(xrg_cpu_interval_valid(2, 1) == 0);
    assert(xrg_cpu_interval_valid(NAN, 1) == 0);
    assert(xrg_cpu_interval_valid(1, INFINITY) == 0);
    assert(xrg_cpu_interval_valid(-1, 1) == 0);
    assert(xrg_ai_sampling_milliseconds() == 5000);
    uint8_t station[4] = {42, 42, 42, 42};
    assert(xrg_metar_station((const uint8_t *)"too-long", 8, station, 4) == -1 && station[0] == 42);
    assert(xrg_metar_station((const uint8_t *)" ksea ", 6, station, 4) == 4);
    assert(memcmp(station, "KSEA", 4) == 0);
    const char *metar = "KSEA 271200Z 00000KT 10SM 00/M02 A3000";
    double weather[10];
    for (int i = 0; i < 10; i++) weather[i] = 99;
    uint32_t weather_flags = 99;
    uint8_t raw_metar[8192] = {42};
    assert(xrg_metar_latest_parse((const uint8_t *)metar, strlen(metar), station, 4,
        1793103000, weather, 10, &weather_flags, raw_metar, 1) == -2);
    assert(weather[0] == 99 && weather[9] == 99 && weather_flags == 99 && raw_metar[0] == 42);
    int32_t raw_count = xrg_metar_latest_parse((const uint8_t *)metar, strlen(metar), station, 4,
        1793103000, weather, 10, &weather_flags, raw_metar, sizeof(raw_metar));
    assert(raw_count == (int32_t)strlen(metar) && memcmp(raw_metar, metar, raw_count) == 0);
    assert(weather[0] == 1793102400 && weather[1] == 0 && (weather_flags & 1));
    assert(weather[5] == 0 && (weather_flags & (1 << 4)) && !(weather_flags & (1 << 5)));
    assert(fabs(weather[9] - 30) < 0.000001);
    assert(xrg_metar_latest_parse(NULL, 1, station, 4, 1793103000,
        weather, 10, &weather_flags, raw_metar, sizeof(raw_metar)) == -1);
    uint8_t archive[4096] = {42};
    assert(xrg_metar_history_parse((const uint8_t *)metar, strlen(metar), station, 4,
        1793103000, archive, 1) == -2 && archive[0] == 42);
    assert(xrg_metar_history_parse(NULL, 1, station, 4,
        1793103000, archive, sizeof(archive)) == -1 && archive[0] == 42);
    assert(xrg_metar_history_parse((const uint8_t *)metar, strlen(metar), station, 4,
        -1, archive, sizeof(archive)) == -1 && archive[0] == 42);
    int32_t archive_count = xrg_metar_history_parse((const uint8_t *)metar, strlen(metar), station, 4,
        1793103000, archive, sizeof(archive)-1);
    assert(archive_count > 0); archive[archive_count] = 0;
    assert(strstr((char *)archive, "\"observed_at\":1793102400") && strstr((char *)archive, "\"temperature_c\":0"));
    uint64_t codex_input = 99, codex_output = 99, codex_total = 99;
    assert(xrg_codex_usage_parse(NULL, 1, &codex_input, &codex_output, &codex_total) == -1);
    assert(codex_input == 99 && codex_output == 99 && codex_total == 99);
    const char *codex = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":6,\"output_tokens\":4,\"total_tokens\":12}}}}";
    assert(xrg_codex_usage_parse((const uint8_t *)"invalid", 7, &codex_input, &codex_output, &codex_total) == 1);
    assert(codex_input == 99 && codex_output == 99 && codex_total == 99);
    assert(xrg_codex_usage_parse((const uint8_t *)codex, strlen(codex), &codex_input, &codex_output, &codex_total) == 0);
    assert(codex_input == 6 && codex_output == 4 && codex_total == 12);
    assert(xrg_log_file_continues(1,2,100,10,1,2,200,20) == 1);
    assert(xrg_log_file_continues(1,2,100,10,1,3,200,20) == 0);
    assert(xrg_log_file_continues(1,2,100,10,3,2,200,20) == 0);
    assert(xrg_log_file_continues(1,2,100,10,1,2,50,20) == 0);
    assert(xrg_log_file_continues(1,2,100,10,1,2,200,5) == 0);
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
    void *accounting = xrg_accounting_create();
    assert(accounting && xrg_accounting_reset(NULL) == -1);
    uint8_t accounting_output[1024] = {42};
    const char *first = "{\"provider\":\"Codex\",\"source\":\"fixture\",\"usage\":{\"input\":0,\"output\":0,\"total\":100},\"models\":{}}";
    assert(xrg_accounting_sample(accounting, (const uint8_t *)first, strlen(first), accounting_output, sizeof(accounting_output)) > 0);
    const char *next = "{\"provider\":\"Codex\",\"source\":\"fixture\",\"usage\":{\"input\":0,\"output\":0,\"total\":110},\"models\":{\"test\":10}}";
    accounting_output[0] = 42;
    assert(xrg_accounting_sample(accounting, (const uint8_t *)next, strlen(next), accounting_output, 1) == -2);
    assert(accounting_output[0] == 42);
    int32_t accounting_count = xrg_accounting_sample(accounting, (const uint8_t *)next, strlen(next), accounting_output, sizeof(accounting_output)-1);
    assert(accounting_count > 0);
    accounting_output[accounting_count] = 0;
    assert(strstr((char *)accounting_output, "\"total\":10") && strstr((char *)accounting_output, "\"test\":10"));
    assert(xrg_accounting_sample(accounting, (const uint8_t *)"bad", 3, accounting_output, sizeof(accounting_output)) == -1);
    assert(xrg_accounting_reset(accounting) == 0);
    accounting_count = xrg_accounting_sample(accounting, (const uint8_t *)next, strlen(next), accounting_output, sizeof(accounting_output)-1);
    assert(accounting_count > 0);
    accounting_output[accounting_count] = 0;
    assert(!strstr((char *)accounting_output, "\"usage\""));
    xrg_accounting_free(accounting);
    xrg_accounting_free(NULL);
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
    uint8_t details[4096] = {42};
    assert(xrg_provider_details_parse((const uint8_t *)record, strlen(record), 0, details, 1) == -2);
    assert(details[0] == 42);
    int32_t details_count = xrg_provider_details_parse((const uint8_t *)record, strlen(record), 0, details, sizeof(details) - 1);
    assert(details_count > 0 && details_count < sizeof(details) - 1);
    details[details_count] = 0;
    assert(strstr((const char *)details, "\"models\"") && strstr((const char *)details, "\"identity\":\"m1\""));
    details[0] = 42;
    assert(xrg_provider_details_parse((const uint8_t *)record, strlen(record), 99, details, sizeof(details)) == -1 && details[0] == 42);
    const char *models = "{\"models\":[{\"name\":\"test\"}]}";
    assert(xrg_model_names_parse((const uint8_t *)models, strlen(models), name, sizeof(name)) == 4);
    const char *metrics = "claude_code_token_usage_total{type=\"input\"} 0\n";
    double cost = 99;
    assert(xrg_metrics_sample_parse((const uint8_t *)metrics, strlen(metrics), &total, &cost) == 1 && total == 0);
    puts("C_ABI_SMOKE_OK");
    return 0;
}
