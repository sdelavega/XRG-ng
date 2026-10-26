/**
 * XRG CLI Test Utility
 *
 * Tests all collectors without GTK for debugging and verification.
 * Usage: xrg-cli-test [options]
 *   -l, --loop        Run continuously with 1-second updates
 *   -n, --iterations  Number of iterations (default: 1, 0 = infinite)
 *   -v, --verbose     Verbose output with all metrics
 *   -m, --module      Test specific module
 *   -h, --help        Show help
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <glib.h>

#include "collectors/cpu_collector.h"
#include "collectors/memory_collector.h"
#include "collectors/network_collector.h"
#include "collectors/disk_collector.h"
#include "collectors/gpu_collector.h"
#include "collectors/sensors_collector.h"
#include "collectors/battery_collector.h"
#include "collectors/aitoken_collector.h"
#include "collectors/process_collector.h"
#include "collectors/tpu_collector.h"

#define HISTORY_SIZE 100
#define CHECKPOINT(name) printf("\n=== CHECKPOINT: %s ===\n", name)
#define SEPARATOR() printf("─────────────────────────────────────────────────\n")

static volatile gboolean running = TRUE;

static void signal_handler(int sig) {
    (void)sig;
    running = FALSE;
    printf("\n[Interrupted]\n");
}

/* Test CPU collector */
static void test_cpu(gboolean verbose) {
    CHECKPOINT("CPU Collector");

    printf("[1/3] Creating CPU collector...\n");
    XRGCPUCollector *cpu = xrg_cpu_collector_new(HISTORY_SIZE);
    if (!cpu) {
        printf("  ERROR: Failed to create CPU collector\n");
        return;
    }
    printf("  OK: CPU collector created\n");

    printf("[2/3] Updating CPU collector...\n");
    xrg_cpu_collector_update(cpu);
    /* CPU usage is computed from the delta between two /proc/stat samples */
    g_usleep(G_USEC_PER_SEC);
    xrg_cpu_collector_update(cpu);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading CPU data...\n");
    gint num_cores = xrg_cpu_collector_get_num_cpus(cpu);
    gdouble total = xrg_cpu_collector_get_total_usage(cpu);
    gdouble load1 = xrg_cpu_collector_get_load_average_1min(cpu);
    gdouble load5 = xrg_cpu_collector_get_load_average_5min(cpu);
    gdouble load15 = xrg_cpu_collector_get_load_average_15min(cpu);

    printf("  Cores: %d\n", num_cores);
    printf("  Total Usage: %.1f%%\n", total);
    printf("  Load Average: %.2f %.2f %.2f\n", load1, load5, load15);

    if (verbose) {
        printf("  Per-core usage:\n");
        for (gint i = 0; i < num_cores && i < 8; i++) {
            printf("    Core %d: %.1f%%\n", i, xrg_cpu_collector_get_core_usage(cpu, i) * 100);
        }
        if (num_cores > 8) printf("    ... (%d more cores)\n", num_cores - 8);
    }

    xrg_cpu_collector_free(cpu);
    printf("  OK: CPU collector freed\n");
}

/* Test Memory collector */
static void test_memory(gboolean verbose) {
    CHECKPOINT("Memory Collector");
    (void)verbose;

    printf("[1/3] Creating Memory collector...\n");
    XRGMemoryCollector *mem = xrg_memory_collector_new(HISTORY_SIZE);
    if (!mem) {
        printf("  ERROR: Failed to create Memory collector\n");
        return;
    }
    printf("  OK: Memory collector created\n");

    printf("[2/3] Updating Memory collector...\n");
    xrg_memory_collector_update(mem);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading Memory data...\n");
    guint64 total = xrg_memory_collector_get_total_memory(mem);
    guint64 used = xrg_memory_collector_get_used_memory(mem);
    guint64 free_mem = xrg_memory_collector_get_free_memory(mem);
    gdouble percent = xrg_memory_collector_get_used_percentage(mem);
    guint64 swap = xrg_memory_collector_get_swap_used(mem);

    printf("  Total: %.1f GB\n", total / (1024.0 * 1024 * 1024));
    printf("  Used: %.1f GB (%.1f%%)\n", used / (1024.0 * 1024 * 1024), percent);
    printf("  Free: %.1f GB\n", free_mem / (1024.0 * 1024 * 1024));
    printf("  Swap Used: %.1f GB\n", swap / (1024.0 * 1024 * 1024));

    xrg_memory_collector_free(mem);
    printf("  OK: Memory collector freed\n");
}

/* Test Network collector */
static void test_network(gboolean verbose) {
    CHECKPOINT("Network Collector");
    (void)verbose;

    printf("[1/3] Creating Network collector...\n");
    XRGNetworkCollector *net = xrg_network_collector_new(HISTORY_SIZE);
    if (!net) {
        printf("  ERROR: Failed to create Network collector\n");
        return;
    }
    printf("  OK: Network collector created\n");

    printf("[2/3] Updating Network collector...\n");
    xrg_network_collector_update(net);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading Network data...\n");
    const gchar *iface = xrg_network_collector_get_primary_interface(net);
    gdouble dl_rate = xrg_network_collector_get_download_rate(net);
    gdouble ul_rate = xrg_network_collector_get_upload_rate(net);
    guint64 rx_total = xrg_network_collector_get_total_rx(net);
    guint64 tx_total = xrg_network_collector_get_total_tx(net);

    printf("  Interface: %s\n", iface ? iface : "(none)");
    printf("  Download Rate: %.2f KB/s\n", dl_rate / 1024.0);
    printf("  Upload Rate: %.2f KB/s\n", ul_rate / 1024.0);
    printf("  RX Total: %.2f MB\n", rx_total / (1024.0 * 1024));
    printf("  TX Total: %.2f MB\n", tx_total / (1024.0 * 1024));

    xrg_network_collector_free(net);
    printf("  OK: Network collector freed\n");
}

/* Test Disk collector */
static void test_disk(gboolean verbose) {
    CHECKPOINT("Disk Collector");
    (void)verbose;

    printf("[1/3] Creating Disk collector...\n");
    XRGDiskCollector *disk = xrg_disk_collector_new(HISTORY_SIZE);
    if (!disk) {
        printf("  ERROR: Failed to create Disk collector\n");
        return;
    }
    printf("  OK: Disk collector created\n");

    printf("[2/3] Updating Disk collector...\n");
    xrg_disk_collector_update(disk);
    /* Rates need a second sample over a real interval */
    g_usleep(G_USEC_PER_SEC);
    xrg_disk_collector_update(disk);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading Disk data...\n");
    const gchar *device = xrg_disk_collector_get_primary_device(disk);
    gdouble read_rate = xrg_disk_collector_get_read_rate(disk);
    gdouble write_rate = xrg_disk_collector_get_write_rate(disk);
    guint64 read_total = xrg_disk_collector_get_total_read(disk);
    guint64 write_total = xrg_disk_collector_get_total_written(disk);

    printf("  Device: %s\n", device ? device : "(none)");
    /* Getters return MB/s (same contract the disk widget relies on) */
    printf("  Read Rate: %.2f MB/s\n", read_rate);
    printf("  Write Rate: %.2f MB/s\n", write_rate);
    printf("  Read Total: %.2f GB\n", read_total / (1024.0 * 1024 * 1024));
    printf("  Write Total: %.2f GB\n", write_total / (1024.0 * 1024 * 1024));

    xrg_disk_collector_free(disk);
    printf("  OK: Disk collector freed\n");
}

/* Test GPU collector */
static void test_gpu(gboolean verbose) {
    CHECKPOINT("GPU Collector");
    (void)verbose;

    printf("[1/3] Creating GPU collector...\n");
    XRGGPUCollector *gpu = xrg_gpu_collector_new(HISTORY_SIZE);
    if (!gpu) {
        printf("  ERROR: Failed to create GPU collector\n");
        return;
    }
    printf("  OK: GPU collector created\n");

    printf("[2/3] Updating GPU collector...\n");
    xrg_gpu_collector_update(gpu);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading GPU data...\n");
    const gchar *name = xrg_gpu_collector_get_name(gpu);
    gdouble usage = xrg_gpu_collector_get_utilization(gpu);
    gdouble mem_used = xrg_gpu_collector_get_memory_used_mb(gpu);
    gdouble mem_total = xrg_gpu_collector_get_memory_total_mb(gpu);
    gdouble temp = xrg_gpu_collector_get_temperature(gpu);

    printf("  Name: %s\n", name ? name : "(none)");
    printf("  Usage: %.1f%%\n", usage);
    printf("  Memory: %.0f / %.0f MB\n", mem_used, mem_total);
    printf("  Temperature: %.1f°C\n", temp);

    xrg_gpu_collector_free(gpu);
    printf("  OK: GPU collector freed\n");
}

/* Test Sensors collector */
static void test_sensors(gboolean verbose) {
    CHECKPOINT("Sensors Collector");

    printf("[1/3] Creating Sensors collector...\n");
    XRGSensorsCollector *sensors = xrg_sensors_collector_new();
    if (!sensors) {
        printf("  ERROR: Failed to create Sensors collector\n");
        return;
    }
    printf("  OK: Sensors collector created\n");
    printf("  lm-sensors available: %s\n", sensors->has_lm_sensors ? "yes" : "no");

    printf("[2/3] Updating Sensors collector...\n");
    xrg_sensors_collector_update(sensors);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading Sensors data...\n");
    GSList *keys = xrg_sensors_collector_get_all_keys(sensors);
    gint count = g_slist_length(keys);
    printf("  Sensor count: %d\n", count);

    if (verbose && count > 0) {
        printf("  Sensors:\n");
        GSList *iter = keys;
        gint i = 0;
        while (iter && i < 10) {
            const gchar *key = (const gchar *)iter->data;
            XRGSensorData *data = xrg_sensors_collector_get_sensor(sensors, key);
            if (data) {
                printf("    [%d] %s: %.1f %s\n", i, data->name ? data->name : key,
                       data->current_value, data->units ? data->units : "");
            }
            iter = iter->next;
            i++;
        }
        if (count > 10) printf("    ... (%d more sensors)\n", count - 10);
    }

    xrg_sensors_collector_free(sensors);
    printf("  OK: Sensors collector freed\n");
}

/* Test Battery collector */
static void test_battery(gboolean verbose) {
    CHECKPOINT("Battery Collector");
    (void)verbose;

    printf("[1/3] Creating Battery collector...\n");
    XRGBatteryCollector *bat = xrg_battery_collector_new();
    if (!bat) {
        printf("  ERROR: Failed to create Battery collector\n");
        return;
    }
    printf("  OK: Battery collector created\n");

    printf("[2/3] Updating Battery collector...\n");
    xrg_battery_collector_update(bat);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading Battery data...\n");
    XRGBatteryStatus status = xrg_battery_collector_get_status(bat);
    gint percent = xrg_battery_collector_get_charge_percent(bat);
    gint minutes = xrg_battery_collector_get_minutes_remaining(bat);

    const gchar *status_str;
    switch (status) {
        case XRG_BATTERY_STATUS_CHARGING: status_str = "Charging"; break;
        case XRG_BATTERY_STATUS_DISCHARGING: status_str = "Discharging"; break;
        case XRG_BATTERY_STATUS_FULL: status_str = "Full"; break;
        case XRG_BATTERY_STATUS_NOT_CHARGING: status_str = "Not Charging"; break;
        case XRG_BATTERY_STATUS_NO_BATTERY: status_str = "No Battery"; break;
        default: status_str = "Unknown"; break;
    }

    printf("  Status: %s\n", status_str);
    printf("  Charge: %d%%\n", percent);
    if (minutes > 0) {
        printf("  Time remaining: %d min\n", minutes);
    }

    xrg_battery_collector_free(bat);
    printf("  OK: Battery collector freed\n");
}

/* Test AI Token collector */
static void test_aitoken(gboolean verbose) {
    CHECKPOINT("AI Token Collector");
    (void)verbose;

    printf("[1/3] Creating AI Token collector...\n");
    XRGAITokenCollector *ai = xrg_aitoken_collector_new(HISTORY_SIZE);
    if (!ai) {
        printf("  ERROR: Failed to create AI Token collector\n");
        return;
    }
    printf("  OK: AI Token collector created\n");

    printf("[2/3] Updating AI Token collector...\n");
    xrg_aitoken_collector_update(ai);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading AI Token data...\n");
    guint64 total = xrg_aitoken_collector_get_total_tokens(ai);
    guint64 input = xrg_aitoken_collector_get_input_tokens(ai);
    guint64 output = xrg_aitoken_collector_get_output_tokens(ai);
    gdouble rate = xrg_aitoken_collector_get_tokens_per_minute(ai);
    const gchar *source = xrg_aitoken_collector_get_source_name(ai);
    const gchar *model = xrg_aitoken_collector_get_current_model(ai);

    printf("  Source: %s\n", source ? source : "(none)");
    printf("  Model: %s\n", model ? model : "(none)");
    printf("  Total: %lu tokens\n", (unsigned long)total);
    printf("  Input: %lu tokens\n", (unsigned long)input);
    printf("  Output: %lu tokens\n", (unsigned long)output);
    printf("  Rate: %.1f tokens/min\n", rate);

    /* Hermes agent (SQLite ~/.hermes/state.db) */
    guint64 hermes = xrg_aitoken_collector_get_hermes_tokens(ai);
    if (hermes > 0) {
        const gchar *hmodel = xrg_aitoken_collector_get_hermes_model(ai);
        gdouble hcost = xrg_aitoken_collector_get_hermes_cost(ai);
        printf("  Hermes: %lu tokens, top model: %s, cost: $%.4f\n",
               (unsigned long)hermes, hmodel ? hmodel : "(none)", hcost);

        GHashTable *hm = xrg_aitoken_collector_get_hermes_model_tokens(ai);
        if (hm && g_hash_table_size(hm) > 0) {
            GHashTableIter it;
            gpointer k, v;
            g_hash_table_iter_init(&it, hm);
            while (g_hash_table_iter_next(&it, &k, &v)) {
                ModelTokens *mt = (ModelTokens *)v;
                printf("    - %s: in=%lu out=%lu\n", (const gchar *)k,
                       (unsigned long)mt->input_tokens,
                       (unsigned long)mt->output_tokens);
            }
        }
    } else {
        printf("  Hermes: (no ~/.hermes/state.db data)\n");
    }

    xrg_aitoken_collector_free(ai);
    printf("  OK: AI Token collector freed\n");
}

/* Test Process collector */
static void test_process(gboolean verbose) {
    CHECKPOINT("Process Collector");

    printf("[1/3] Creating Process collector...\n");
    XRGProcessCollector *proc = xrg_process_collector_new(HISTORY_SIZE);
    if (!proc) {
        printf("  ERROR: Failed to create Process collector\n");
        return;
    }
    printf("  OK: Process collector created\n");

    printf("[2/3] Updating Process collector...\n");
    xrg_process_collector_update(proc);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading Process data...\n");
    gint count = xrg_process_collector_get_process_count(proc);
    gint total = xrg_process_collector_get_total_processes(proc);
    gint running_procs = xrg_process_collector_get_running_processes(proc);

    printf("  Visible processes: %d\n", count);
    printf("  Total processes: %d\n", total);
    printf("  Running: %d\n", running_procs);

    if (verbose) {
        printf("  Top 5 by CPU:\n");
        for (gint i = 0; i < 5 && i < count; i++) {
            XRGProcessInfo *info = xrg_process_collector_get_process(proc, i);
            if (info) {
                printf("    [%d] %s (PID %d): %.1f%% CPU, %.1f%% MEM\n",
                       i + 1, info->name, info->pid, info->cpu_percent, info->mem_percent);
            }
        }
    }

    xrg_process_collector_free(proc);
    printf("  OK: Process collector freed\n");
}

/* Test TPU collector */
static void test_tpu(gboolean verbose) {
    CHECKPOINT("TPU Collector");

    printf("[1/3] Creating TPU collector...\n");
    XRGTPUCollector *tpu = xrg_tpu_collector_new(HISTORY_SIZE);
    if (!tpu) {
        printf("  ERROR: Failed to create TPU collector\n");
        return;
    }
    printf("  OK: TPU collector created\n");

    printf("[2/3] Updating TPU collector...\n");
    xrg_tpu_collector_update(tpu);
    printf("  OK: Update complete\n");

    printf("[3/3] Reading TPU data...\n");
    XRGTPUStatus status = xrg_tpu_collector_get_status(tpu);
    XRGTPUType type = xrg_tpu_collector_get_type(tpu);
    const gchar *name = xrg_tpu_collector_get_name(tpu);
    const gchar *path = xrg_tpu_collector_get_device_path(tpu);

    const gchar *status_str;
    switch (status) {
        case XRG_TPU_STATUS_CONNECTED: status_str = "Connected"; break;
        case XRG_TPU_STATUS_BUSY: status_str = "Busy"; break;
        case XRG_TPU_STATUS_ERROR: status_str = "Error"; break;
        default: status_str = "Disconnected"; break;
    }

    const gchar *type_str;
    switch (type) {
        case XRG_TPU_TYPE_USB: type_str = "USB"; break;
        case XRG_TPU_TYPE_PCIE: type_str = "PCIe"; break;
        default: type_str = "None"; break;
    }

    printf("  Status: %s\n", status_str);
    printf("  Type: %s\n", type_str);
    printf("  Name: %s\n", name ? name : "(none)");
    printf("  Path: %s\n", path ? path : "(none)");

    if (verbose) {
        gdouble rate = xrg_tpu_collector_get_inferences_per_second(tpu);
        gdouble latency = xrg_tpu_collector_get_last_latency_ms(tpu);
        guint64 total = xrg_tpu_collector_get_total_inferences(tpu);
        printf("  Inferences/sec: %.2f\n", rate);
        printf("  Last latency: %.2f ms\n", latency);
        printf("  Total inferences: %lu\n", (unsigned long)total);
        printf("  Stats file: %s\n", xrg_tpu_collector_get_stats_file_path());
    }

    xrg_tpu_collector_free(tpu);
    printf("  OK: TPU collector freed\n");
}

static void print_usage(const char *prog) {
    printf("XRG-ng CLI Test Utility\n");
    printf("Usage: %s [options]\n", prog);
    printf("\nOptions:\n");
    printf("  -l, --loop         Run continuously with 1-second updates\n");
    printf("  -n, --iterations N Number of iterations (default: 1, 0 = infinite)\n");
    printf("  -v, --verbose      Verbose output with all metrics\n");
    printf("  -m, --module NAME  Test specific module:\n");
    printf("                     cpu, memory, network, disk, gpu,\n");
    printf("                     sensors, battery, aitoken, process, tpu\n");
    printf("  -h, --help         Show this help\n");
    printf("\nExamples:\n");
    printf("  %s                 Run all tests once\n", prog);
    printf("  %s -v              Run all tests with verbose output\n", prog);
    printf("  %s -m tpu -v       Test only TPU collector verbosely\n", prog);
    printf("  %s -l -n 10        Run 10 update cycles\n", prog);
    printf("  %s -l -n 0         Run continuously until Ctrl+C\n", prog);
}

int main(int argc, char *argv[]) {
    gboolean loop = FALSE;
    gboolean verbose = FALSE;
    gint iterations = 1;
    const gchar *module = NULL;

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-l") == 0 || strcmp(argv[i], "--loop") == 0) {
            loop = TRUE;
        } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
            verbose = TRUE;
        } else if ((strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--iterations") == 0) && i + 1 < argc) {
            iterations = atoi(argv[++i]);
        } else if ((strcmp(argv[i], "-m") == 0 || strcmp(argv[i], "--module") == 0) && i + 1 < argc) {
            module = argv[++i];
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    /* Setup signal handler for Ctrl+C */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    printf("╔═══════════════════════════════════════════════════╗\n");
    printf("║           XRG-ng CLI Test Utility                    ║\n");
    printf("╚═══════════════════════════════════════════════════╝\n\n");

    gint iteration = 0;
    do {
        if (loop && (iterations == 0 || iterations > 1)) {
            printf("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
            printf("  Iteration %d%s\n", iteration + 1,
                   iterations == 0 ? " (Ctrl+C to stop)" : "");
            printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        }

        if (module == NULL) {
            /* Test all collectors */
            test_cpu(verbose);
            test_memory(verbose);
            test_network(verbose);
            test_disk(verbose);
            test_gpu(verbose);
            test_sensors(verbose);
            test_battery(verbose);
            test_aitoken(verbose);
            test_process(verbose);
            test_tpu(verbose);
        } else {
            /* Test specific module */
            if (strcmp(module, "cpu") == 0) test_cpu(verbose);
            else if (strcmp(module, "memory") == 0) test_memory(verbose);
            else if (strcmp(module, "network") == 0) test_network(verbose);
            else if (strcmp(module, "disk") == 0) test_disk(verbose);
            else if (strcmp(module, "gpu") == 0) test_gpu(verbose);
            else if (strcmp(module, "sensors") == 0) test_sensors(verbose);
            else if (strcmp(module, "battery") == 0) test_battery(verbose);
            else if (strcmp(module, "aitoken") == 0) test_aitoken(verbose);
            else if (strcmp(module, "process") == 0) test_process(verbose);
            else if (strcmp(module, "tpu") == 0) test_tpu(verbose);
            else {
                fprintf(stderr, "Unknown module: %s\n", module);
                return 1;
            }
        }

        iteration++;

        if (loop && running && (iterations == 0 || iteration < iterations)) {
            sleep(1);
        }

    } while (loop && running && (iterations == 0 || iteration < iterations));

    SEPARATOR();
    printf("All tests completed successfully!\n");
    printf("Iterations: %d\n", iteration);

    return 0;
}
