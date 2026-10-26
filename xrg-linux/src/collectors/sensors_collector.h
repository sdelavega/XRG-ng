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

#ifndef XRG_SENSORS_COLLECTOR_H
#define XRG_SENSORS_COLLECTOR_H

#include <glib.h>
#include "core/dataset.h"

/* Sensor types */
typedef enum {
    XRG_SENSOR_TYPE_TEMP,
    XRG_SENSOR_TYPE_FAN,
    XRG_SENSOR_TYPE_VOLTAGE,
    XRG_SENSOR_TYPE_POWER
} XRGSensorType;

/* Individual sensor data */
typedef struct {
    gchar *key;                 /* Unique sensor identifier */
    gchar *name;                /* Human-readable name */
    gchar *chip_name;           /* Chip/device name */
    gchar *units;               /* Units (°C, RPM, V, W) */
    XRGSensorType type;
    gdouble current_value;
    gdouble min_value;
    gdouble max_value;
    XRGDataset *dataset;        /* Time-series data */
    gboolean is_enabled;
} XRGSensorData;

/* Sensors collector */
typedef struct {
    GHashTable *sensors;        /* Key -> XRGSensorData* */
    GSList *sensor_keys;        /* Ordered list of sensor keys */
    gint num_samples;
    gboolean has_lm_sensors;    /* Whether lm-sensors library is available */
} XRGSensorsCollector;

/* Constructor/Destructor */
XRGSensorsCollector* xrg_sensors_collector_new(void);
void xrg_sensors_collector_free(XRGSensorsCollector *collector);

/* Data collection */
void xrg_sensors_collector_update(XRGSensorsCollector *collector);
void xrg_sensors_collector_set_data_size(XRGSensorsCollector *collector, gint num_samples);

/* Accessors */
XRGSensorData* xrg_sensors_collector_get_sensor(XRGSensorsCollector *collector, const gchar *key);
GSList* xrg_sensors_collector_get_all_keys(XRGSensorsCollector *collector);
GSList* xrg_sensors_collector_get_temp_sensors(XRGSensorsCollector *collector);
GSList* xrg_sensors_collector_get_fan_sensors(XRGSensorsCollector *collector);

/* Sensor data helpers */
void xrg_sensor_data_free(XRGSensorData *sensor);

#endif /* XRG_SENSORS_COLLECTOR_H */
