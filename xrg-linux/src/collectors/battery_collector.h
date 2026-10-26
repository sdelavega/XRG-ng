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

#ifndef XRG_BATTERY_COLLECTOR_H
#define XRG_BATTERY_COLLECTOR_H

#include <glib.h>
#include "core/dataset.h"

typedef enum {
    XRG_BATTERY_STATUS_UNKNOWN = 0,
    XRG_BATTERY_STATUS_DISCHARGING = 1,
    XRG_BATTERY_STATUS_CHARGING = 2,
    XRG_BATTERY_STATUS_FULL = 3,
    XRG_BATTERY_STATUS_NOT_CHARGING = 4,
    XRG_BATTERY_STATUS_NO_BATTERY = 5
} XRGBatteryStatus;

typedef struct {
    gint64 current_charge;      /* Current charge in µWh or µAh */
    gint64 total_capacity;      /* Total capacity in µWh or µAh */
    gdouble voltage;            /* Voltage in V */
    gdouble current;            /* Current in A (positive = charging, negative = discharging) */
    gint minutes_remaining;     /* Estimated minutes remaining */
    gboolean is_charging;
    gboolean is_fully_charged;
    gboolean is_plugged_in;
    gchar *battery_path;        /* Path in /sys/class/power_supply/ */
} XRGBatteryInfo;

typedef struct {
    GSList *batteries;          /* List of XRGBatteryInfo* */
    XRGDataset *charge_watts;   /* Charging power over time */
    XRGDataset *discharge_watts; /* Discharging power over time */
    gint num_samples;
} XRGBatteryCollector;

/* Constructor/Destructor */
XRGBatteryCollector* xrg_battery_collector_new(void);
void xrg_battery_collector_free(XRGBatteryCollector *collector);

/* Data collection */
void xrg_battery_collector_update(XRGBatteryCollector *collector);
void xrg_battery_collector_set_data_size(XRGBatteryCollector *collector, gint num_samples);

/* Accessors */
XRGBatteryStatus xrg_battery_collector_get_status(XRGBatteryCollector *collector);
gint xrg_battery_collector_get_minutes_remaining(XRGBatteryCollector *collector);
gint64 xrg_battery_collector_get_total_charge(XRGBatteryCollector *collector);
gint64 xrg_battery_collector_get_total_capacity(XRGBatteryCollector *collector);
gint xrg_battery_collector_get_charge_percent(XRGBatteryCollector *collector);

#endif /* XRG_BATTERY_COLLECTOR_H */
