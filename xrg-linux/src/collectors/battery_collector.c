/*
 * XRG (X Resource Graph):  A system resource grapher for Linux.
 * Copyright (C) 2002-2024 Mike Piatek-Jimenez / Gaucho Software, LLC.
 * Copyright (C) 2025-2026 Marc Shade.
 * Copyright (C) 2026 Stephen de la Vega.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "battery_collector.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>

#define POWER_SUPPLY_PATH "/sys/class/power_supply"

/* Helper function to read a sysfs file as integer */
static gint64 read_sysfs_int64(const gchar *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    gint64 value = 0;
    fscanf(f, "%ld", &value);
    fclose(f);
    return value;
}

/* Helper function to read a sysfs file as string */
static gchar* read_sysfs_string(const gchar *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;

    gchar buffer[256];
    if (fgets(buffer, sizeof(buffer), f)) {
        fclose(f);
        /* Remove newline */
        gsize len = strlen(buffer);
        if (len > 0 && buffer[len-1] == '\n') {
            buffer[len-1] = '\0';
        }
        return g_strdup(buffer);
    }

    fclose(f);
    return NULL;
}

/* Free battery info */
static void xrg_battery_info_free(XRGBatteryInfo *info) {
    if (!info) return;
    g_free(info->battery_path);
    g_free(info);
}

/* Read battery information from sysfs */
static XRGBatteryInfo* xrg_battery_info_read(const gchar *battery_name) {
    XRGBatteryInfo *info = g_new0(XRGBatteryInfo, 1);
    info->battery_path = g_strdup_printf("%s/%s", POWER_SUPPLY_PATH, battery_name);

    /* Read type to verify it's a battery */
    gchar *type_path = g_strdup_printf("%s/type", info->battery_path);
    gchar *type = read_sysfs_string(type_path);
    g_free(type_path);

    if (!type || strcmp(type, "Battery") != 0) {
        g_free(type);
        xrg_battery_info_free(info);
        return NULL;
    }
    g_free(type);

    /* Read status */
    gchar *status_path = g_strdup_printf("%s/status", info->battery_path);
    gchar *status = read_sysfs_string(status_path);
    g_free(status_path);

    if (status) {
        info->is_charging = (strcmp(status, "Charging") == 0);
        info->is_fully_charged = (strcmp(status, "Full") == 0);
        info->is_plugged_in = info->is_charging || info->is_fully_charged ||
                              (strcmp(status, "Not charging") == 0);
        g_free(status);
    }

    /* Read energy/charge values (try energy first, then charge) */
    gchar *energy_now_path = g_strdup_printf("%s/energy_now", info->battery_path);
    gchar *energy_full_path = g_strdup_printf("%s/energy_full", info->battery_path);
    gchar *charge_now_path = g_strdup_printf("%s/charge_now", info->battery_path);
    gchar *charge_full_path = g_strdup_printf("%s/charge_full", info->battery_path);

    info->current_charge = read_sysfs_int64(energy_now_path);
    info->total_capacity = read_sysfs_int64(energy_full_path);

    /* If energy not available, try charge */
    if (info->current_charge == 0) {
        info->current_charge = read_sysfs_int64(charge_now_path);
    }
    if (info->total_capacity == 0) {
        info->total_capacity = read_sysfs_int64(charge_full_path);
    }

    g_free(energy_now_path);
    g_free(energy_full_path);
    g_free(charge_now_path);
    g_free(charge_full_path);

    /* Read voltage (in µV) */
    gchar *voltage_path = g_strdup_printf("%s/voltage_now", info->battery_path);
    gint64 voltage_uv = read_sysfs_int64(voltage_path);
    info->voltage = (gdouble)voltage_uv / 1000000.0; /* Convert µV to V */
    g_free(voltage_path);

    /* Read current (in µA) */
    gchar *current_path = g_strdup_printf("%s/current_now", info->battery_path);
    gint64 current_ua = read_sysfs_int64(current_path);
    info->current = (gdouble)current_ua / 1000000.0; /* Convert µA to A */
    g_free(current_path);

    /* If charging, current is positive; if discharging, make it negative */
    if (!info->is_charging && info->current > 0) {
        info->current = -info->current;
    }

    /* Estimate time remaining (very rough estimate) */
    if (info->current != 0.0 && info->total_capacity > 0) {
        if (info->is_charging) {
            /* Time to full */
            gint64 remaining = info->total_capacity - info->current_charge;
            gdouble hours = (gdouble)remaining / (info->current * 1000000.0);
            info->minutes_remaining = (gint)(hours * 60.0);
        } else {
            /* Time to empty */
            gdouble hours = (gdouble)info->current_charge / (-info->current * 1000000.0);
            info->minutes_remaining = (gint)(hours * 60.0);
        }
    } else {
        info->minutes_remaining = 0;
    }

    return info;
}

/* Constructor */
XRGBatteryCollector* xrg_battery_collector_new(void) {
    XRGBatteryCollector *collector = g_new0(XRGBatteryCollector, 1);

    collector->batteries = NULL;
    collector->charge_watts = xrg_dataset_new(300);  /* 5 minutes at 1Hz */
    collector->discharge_watts = xrg_dataset_new(300);
    collector->num_samples = 300;

    return collector;
}

/* Destructor */
void xrg_battery_collector_free(XRGBatteryCollector *collector) {
    if (!collector) return;

    /* Free battery list */
    g_slist_free_full(collector->batteries, (GDestroyNotify)xrg_battery_info_free);

    /* Free datasets */
    if (collector->charge_watts) xrg_dataset_free(collector->charge_watts);
    if (collector->discharge_watts) xrg_dataset_free(collector->discharge_watts);

    g_free(collector);
}

/* Set data size */
void xrg_battery_collector_set_data_size(XRGBatteryCollector *collector, gint num_samples) {
    if (!collector) return;

    xrg_dataset_resize(collector->charge_watts, num_samples);
    xrg_dataset_resize(collector->discharge_watts, num_samples);
    collector->num_samples = num_samples;
}

/* Update battery information */
void xrg_battery_collector_update(XRGBatteryCollector *collector) {
    if (!collector) return;

    /* Free old battery list */
    g_slist_free_full(collector->batteries, (GDestroyNotify)xrg_battery_info_free);
    collector->batteries = NULL;

    /* Scan power supply directory for batteries */
    DIR *dir = opendir(POWER_SUPPLY_PATH);
    if (!dir) return;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        /* Skip HID batteries (Bluetooth devices) - they can hang when queried */
        if (strncmp(entry->d_name, "hid-", 4) == 0) {
            continue;
        }

        /* Skip peripheral batteries (mice, keyboards, gamepads): they expose
         * scope=Device, while system batteries have no scope or scope=System */
        gchar *scope_path = g_strdup_printf(POWER_SUPPLY_PATH "/%s/scope", entry->d_name);
        gchar *scope = read_sysfs_string(scope_path);
        g_free(scope_path);
        if (scope) {
            gboolean is_peripheral = (strcmp(scope, "Device") == 0);
            g_free(scope);
            if (is_peripheral) {
                continue;
            }
        }

        XRGBatteryInfo *info = xrg_battery_info_read(entry->d_name);
        if (info) {
            collector->batteries = g_slist_append(collector->batteries, info);
        }
    }
    closedir(dir);

    /* Calculate total watts */
    gdouble charge_watts_sum = 0.0;
    gdouble discharge_watts_sum = 0.0;

    for (GSList *l = collector->batteries; l != NULL; l = l->next) {
        XRGBatteryInfo *battery = (XRGBatteryInfo *)l->data;
        gdouble watts = battery->current * battery->voltage;

        if (watts < 0) {
            discharge_watts_sum += -watts;
        } else {
            charge_watts_sum += watts;
        }
    }

    /* Add to datasets */
    xrg_dataset_add_value(collector->charge_watts, charge_watts_sum);
    xrg_dataset_add_value(collector->discharge_watts, discharge_watts_sum);
}

/* Get battery status */
XRGBatteryStatus xrg_battery_collector_get_status(XRGBatteryCollector *collector) {
    if (!collector || !collector->batteries) {
        return XRG_BATTERY_STATUS_NO_BATTERY;
    }

    /* Use first battery */
    XRGBatteryInfo *battery = (XRGBatteryInfo *)collector->batteries->data;

    if (battery->is_plugged_in && battery->is_fully_charged) {
        return XRG_BATTERY_STATUS_FULL;
    } else if (battery->is_plugged_in && battery->is_charging) {
        return XRG_BATTERY_STATUS_CHARGING;
    } else if (battery->is_plugged_in && !battery->is_charging) {
        return XRG_BATTERY_STATUS_NOT_CHARGING;
    } else {
        return XRG_BATTERY_STATUS_DISCHARGING;
    }
}

/* Get minutes remaining */
gint xrg_battery_collector_get_minutes_remaining(XRGBatteryCollector *collector) {
    if (!collector || !collector->batteries) return 0;

    gint max_minutes = 0;
    for (GSList *l = collector->batteries; l != NULL; l = l->next) {
        XRGBatteryInfo *battery = (XRGBatteryInfo *)l->data;
        if (battery->minutes_remaining > max_minutes) {
            max_minutes = battery->minutes_remaining;
        }
    }

    return max_minutes;
}

/* Get total charge */
gint64 xrg_battery_collector_get_total_charge(XRGBatteryCollector *collector) {
    if (!collector || !collector->batteries) return 0;

    gint64 total = 0;
    for (GSList *l = collector->batteries; l != NULL; l = l->next) {
        XRGBatteryInfo *battery = (XRGBatteryInfo *)l->data;
        total += battery->current_charge;
    }

    return total;
}

/* Get total capacity */
gint64 xrg_battery_collector_get_total_capacity(XRGBatteryCollector *collector) {
    if (!collector || !collector->batteries) return 0;

    gint64 total = 0;
    for (GSList *l = collector->batteries; l != NULL; l = l->next) {
        XRGBatteryInfo *battery = (XRGBatteryInfo *)l->data;
        total += battery->total_capacity;
    }

    return total;
}

/* Get charge percentage */
gint xrg_battery_collector_get_charge_percent(XRGBatteryCollector *collector) {
    gint64 charge = xrg_battery_collector_get_total_charge(collector);
    gint64 capacity = xrg_battery_collector_get_total_capacity(collector);

    if (charge > 0 && capacity > 0) {
        return (gint)(100.0 * charge / capacity + 0.5);
    }

    return 0;
}
