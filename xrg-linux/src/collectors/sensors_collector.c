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

#include "sensors_collector.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>
#include <sys/types.h>

#ifdef HAVE_SENSORS
#include <sensors/sensors.h>
#endif

#define HWMON_PATH "/sys/class/hwmon"
#define THERMAL_PATH "/sys/class/thermal"

/* Helper: read a single value from sysfs */
static gdouble read_sysfs_value(const gchar *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0.0;

    gdouble value = 0.0;
    fscanf(f, "%lf", &value);
    fclose(f);
    return value;
}

/* Helper: read label from sysfs */
static gchar* read_sysfs_label(const gchar *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;

    gchar buffer[256];
    if (fgets(buffer, sizeof(buffer), f)) {
        fclose(f);
        gsize len = strlen(buffer);
        if (len > 0 && buffer[len-1] == '\n') {
            buffer[len-1] = '\0';
        }
        return g_strdup(buffer);
    }

    fclose(f);
    return NULL;
}

/* Free sensor data */
void xrg_sensor_data_free(XRGSensorData *sensor) {
    if (!sensor) return;

    g_free(sensor->key);
    g_free(sensor->name);
    g_free(sensor->chip_name);
    g_free(sensor->units);
    if (sensor->dataset) xrg_dataset_free(sensor->dataset);
    g_free(sensor);
}

#ifdef HAVE_SENSORS
/* Initialize lm-sensors library */
static gboolean init_lm_sensors(XRGSensorsCollector *collector) {
    FILE *config = fopen("/etc/sensors3.conf", "r");
    if (!config) {
        config = fopen("/etc/sensors.conf", "r");
    }

    if (sensors_init(config) != 0) {
        if (config) fclose(config);
        return FALSE;
    }

    if (config) fclose(config);
    collector->has_lm_sensors = TRUE;
    return TRUE;
}

/* Collect sensors using lm-sensors library */
static void collect_lm_sensors(XRGSensorsCollector *collector) {
    const sensors_chip_name *chip;
    int chip_nr = 0;

    while ((chip = sensors_get_detected_chips(NULL, &chip_nr)) != NULL) {
        gchar chip_name_buf[256];
        sensors_snprintf_chip_name(chip_name_buf, sizeof(chip_name_buf), chip);

        const sensors_feature *feature;
        int feature_nr = 0;

        while ((feature = sensors_get_features(chip, &feature_nr)) != NULL) {
            XRGSensorType type;
            const gchar *units = "";

            switch (feature->type) {
                case SENSORS_FEATURE_TEMP:
                    type = XRG_SENSOR_TYPE_TEMP;
                    units = "°C";
                    break;
                case SENSORS_FEATURE_FAN:
                    type = XRG_SENSOR_TYPE_FAN;
                    units = "RPM";
                    break;
                case SENSORS_FEATURE_IN:
                    type = XRG_SENSOR_TYPE_VOLTAGE;
                    units = "V";
                    break;
                case SENSORS_FEATURE_POWER:
                    type = XRG_SENSOR_TYPE_POWER;
                    units = "W";
                    break;
                default:
                    continue;  /* Skip unsupported types */
            }

            /* Get sensor label */
            gchar *label = sensors_get_label(chip, feature);
            if (!label) continue;

            /* Create unique key */
            gchar *key = g_strdup_printf("%s_%s", chip_name_buf, label);

            /* Check if sensor already exists */
            XRGSensorData *sensor = g_hash_table_lookup(collector->sensors, key);
            if (!sensor) {
                /* Create new sensor */
                sensor = g_new0(XRGSensorData, 1);
                sensor->key = g_strdup(key);
                sensor->name = g_strdup(label);
                sensor->chip_name = g_strdup(chip_name_buf);
                sensor->units = g_strdup(units);
                sensor->type = type;
                sensor->dataset = xrg_dataset_new(collector->num_samples);
                sensor->is_enabled = TRUE;
                sensor->min_value = 0.0;
                sensor->max_value = 100.0;

                g_hash_table_insert(collector->sensors, g_strdup(key), sensor);
                collector->sensor_keys = g_slist_append(collector->sensor_keys, g_strdup(key));
            }

            /* Get current value */
            const sensors_subfeature *subfeature = sensors_get_subfeature(chip, feature, SENSORS_SUBFEATURE_TEMP_INPUT);
            if (!subfeature) {
                subfeature = sensors_get_subfeature(chip, feature, SENSORS_SUBFEATURE_FAN_INPUT);
            }
            if (!subfeature) {
                subfeature = sensors_get_subfeature(chip, feature, SENSORS_SUBFEATURE_IN_INPUT);
            }
            if (!subfeature) {
                subfeature = sensors_get_subfeature(chip, feature, SENSORS_SUBFEATURE_POWER_INPUT);
            }

            if (subfeature) {
                double value = 0.0;
                if (sensors_get_value(chip, subfeature->number, &value) == 0) {
                    sensor->current_value = value;
                    xrg_dataset_add_value(sensor->dataset, value);
                }
            }

            g_free(label);
            g_free(key);
        }
    }
}
#endif

/* Fallback: Collect sensors from sysfs */
static void collect_sysfs_sensors(XRGSensorsCollector *collector) {
    /* Read from /sys/class/hwmon/ */
    DIR *hwmon_dir = opendir(HWMON_PATH);
    if (hwmon_dir) {
        struct dirent *hwmon_entry;
        while ((hwmon_entry = readdir(hwmon_dir)) != NULL) {
            if (hwmon_entry->d_name[0] == '.') continue;

            gchar *hwmon_path = g_strdup_printf("%s/%s", HWMON_PATH, hwmon_entry->d_name);

            /* Read device name */
            gchar *name_path = g_strdup_printf("%s/name", hwmon_path);
            gchar *chip_name = read_sysfs_label(name_path);
            g_free(name_path);

            if (!chip_name) chip_name = g_strdup(hwmon_entry->d_name);

            /* Scan for temp*_input files */
            DIR *device_dir = opendir(hwmon_path);
            if (device_dir) {
                struct dirent *file_entry;
                while ((file_entry = readdir(device_dir)) != NULL) {
                    if (g_str_has_prefix(file_entry->d_name, "temp") && g_str_has_suffix(file_entry->d_name, "_input")) {
                        /* Read temperature */
                        gchar *temp_input_path = g_strdup_printf("%s/%s", hwmon_path, file_entry->d_name);
                        gdouble temp_millidegrees = read_sysfs_value(temp_input_path);
                        gdouble temp_celsius = temp_millidegrees / 1000.0;

                        /* Read label if available */
                        gchar temp_num[32];
                        g_strlcpy(temp_num, file_entry->d_name + 4, sizeof(temp_num));  /* Skip "temp" */
                        gchar *p = strchr(temp_num, '_');
                        if (p) *p = '\0';

                        gchar *label_path = g_strdup_printf("%s/temp%s_label", hwmon_path, temp_num);
                        gchar *label = read_sysfs_label(label_path);
                        g_free(label_path);

                        if (!label) label = g_strdup_printf("temp%s", temp_num);

                        /* Create sensor key */
                        gchar *key = g_strdup_printf("%s_%s", chip_name, label);

                        /* Create or update sensor */
                        XRGSensorData *sensor = g_hash_table_lookup(collector->sensors, key);
                        if (!sensor) {
                            sensor = g_new0(XRGSensorData, 1);
                            sensor->key = g_strdup(key);
                            sensor->name = g_strdup(label);
                            sensor->chip_name = g_strdup(chip_name);
                            sensor->units = g_strdup("°C");
                            sensor->type = XRG_SENSOR_TYPE_TEMP;
                            sensor->dataset = xrg_dataset_new(collector->num_samples);
                            sensor->is_enabled = TRUE;
                            sensor->min_value = 0.0;
                            sensor->max_value = 100.0;

                            g_hash_table_insert(collector->sensors, g_strdup(key), sensor);
                            collector->sensor_keys = g_slist_append(collector->sensor_keys, g_strdup(key));
                        }

                        sensor->current_value = temp_celsius;
                        xrg_dataset_add_value(sensor->dataset, temp_celsius);

                        g_free(temp_input_path);
                        g_free(label);
                        g_free(key);
                    } else if (g_str_has_prefix(file_entry->d_name, "fan") && g_str_has_suffix(file_entry->d_name, "_input")) {
                        /* Read fan speed */
                        gchar *fan_input_path = g_strdup_printf("%s/%s", hwmon_path, file_entry->d_name);
                        gdouble fan_rpm = read_sysfs_value(fan_input_path);

                        /* Read label if available */
                        gchar fan_num[32];
                        g_strlcpy(fan_num, file_entry->d_name + 3, sizeof(fan_num));  /* Skip "fan" */
                        gchar *p = strchr(fan_num, '_');
                        if (p) *p = '\0';

                        gchar *label_path = g_strdup_printf("%s/fan%s_label", hwmon_path, fan_num);
                        gchar *label = read_sysfs_label(label_path);
                        g_free(label_path);

                        if (!label) label = g_strdup_printf("fan%s", fan_num);

                        /* Create sensor key */
                        gchar *key = g_strdup_printf("%s_%s", chip_name, label);

                        /* Create or update sensor */
                        XRGSensorData *sensor = g_hash_table_lookup(collector->sensors, key);
                        if (!sensor) {
                            sensor = g_new0(XRGSensorData, 1);
                            sensor->key = g_strdup(key);
                            sensor->name = g_strdup(label);
                            sensor->chip_name = g_strdup(chip_name);
                            sensor->units = g_strdup("RPM");
                            sensor->type = XRG_SENSOR_TYPE_FAN;
                            sensor->dataset = xrg_dataset_new(collector->num_samples);
                            sensor->is_enabled = TRUE;
                            sensor->min_value = 0.0;
                            sensor->max_value = 5000.0;

                            g_hash_table_insert(collector->sensors, g_strdup(key), sensor);
                            collector->sensor_keys = g_slist_append(collector->sensor_keys, g_strdup(key));
                        }

                        sensor->current_value = fan_rpm;
                        xrg_dataset_add_value(sensor->dataset, fan_rpm);

                        g_free(fan_input_path);
                        g_free(label);
                        g_free(key);
                    }
                }
                closedir(device_dir);
            }

            g_free(chip_name);
            g_free(hwmon_path);
        }
        closedir(hwmon_dir);
    }
}

/* Constructor */
XRGSensorsCollector* xrg_sensors_collector_new(void) {
    XRGSensorsCollector *collector = g_new0(XRGSensorsCollector, 1);

    collector->sensors = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)xrg_sensor_data_free);
    collector->sensor_keys = NULL;
    collector->num_samples = 300;  /* 5 minutes at 1Hz */
    collector->has_lm_sensors = FALSE;

#ifdef HAVE_SENSORS
    init_lm_sensors(collector);
#endif

    return collector;
}

/* Destructor */
void xrg_sensors_collector_free(XRGSensorsCollector *collector) {
    if (!collector) return;

#ifdef HAVE_SENSORS
    if (collector->has_lm_sensors) {
        sensors_cleanup();
    }
#endif

    g_hash_table_destroy(collector->sensors);
    g_slist_free_full(collector->sensor_keys, g_free);
    g_free(collector);
}

/* Set data size */
void xrg_sensors_collector_set_data_size(XRGSensorsCollector *collector, gint num_samples) {
    if (!collector) return;

    collector->num_samples = num_samples;

    /* Resize all existing sensors */
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, collector->sensors);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        XRGSensorData *sensor = (XRGSensorData *)value;
        xrg_dataset_resize(sensor->dataset, num_samples);
    }
}

/* Update sensors */
void xrg_sensors_collector_update(XRGSensorsCollector *collector) {
    if (!collector) return;

#ifdef HAVE_SENSORS
    if (collector->has_lm_sensors) {
        collect_lm_sensors(collector);
    } else {
        collect_sysfs_sensors(collector);
    }
#else
    collect_sysfs_sensors(collector);
#endif
}

/* Get sensor by key */
XRGSensorData* xrg_sensors_collector_get_sensor(XRGSensorsCollector *collector, const gchar *key) {
    if (!collector || !key) return NULL;
    return g_hash_table_lookup(collector->sensors, key);
}

/* Get all sensor keys */
GSList* xrg_sensors_collector_get_all_keys(XRGSensorsCollector *collector) {
    if (!collector) return NULL;
    return collector->sensor_keys;
}

/* Get temperature sensors */
GSList* xrg_sensors_collector_get_temp_sensors(XRGSensorsCollector *collector) {
    if (!collector) return NULL;

    GSList *temp_sensors = NULL;
    for (GSList *l = collector->sensor_keys; l != NULL; l = l->next) {
        const gchar *key = (const gchar *)l->data;
        XRGSensorData *sensor = g_hash_table_lookup(collector->sensors, key);
        if (sensor && sensor->type == XRG_SENSOR_TYPE_TEMP) {
            temp_sensors = g_slist_append(temp_sensors, sensor);
        }
    }

    return temp_sensors;
}

/* Get fan sensors */
GSList* xrg_sensors_collector_get_fan_sensors(XRGSensorsCollector *collector) {
    if (!collector) return NULL;

    GSList *fan_sensors = NULL;
    for (GSList *l = collector->sensor_keys; l != NULL; l = l->next) {
        const gchar *key = (const gchar *)l->data;
        XRGSensorData *sensor = g_hash_table_lookup(collector->sensors, key);
        if (sensor && sensor->type == XRG_SENSOR_TYPE_FAN) {
            fan_sensors = g_slist_append(fan_sensors, sensor);
        }
    }

    return fan_sensors;
}
