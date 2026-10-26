cmake_minimum_required(VERSION 3.16)
project(XRG-ng VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wextra -O2")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -g -O0 -DDEBUG")

# Find required packages
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK3 REQUIRED gtk+-3.0>=3.24)
pkg_check_modules(CAIRO REQUIRED cairo>=1.16)
pkg_check_modules(GLIB REQUIRED glib-2.0>=2.66)
pkg_check_modules(SQLITE3 REQUIRED sqlite3)
pkg_check_modules(CURL REQUIRED libcurl)
pkg_check_modules(JSON_GLIB REQUIRED json-glib-1.0)

# Find optional packages
pkg_check_modules(SENSORS libsensors)
if(NOT SENSORS_FOUND)
    # Some distros (e.g. Fedora) ship libsensors without a pkg-config file
    find_library(SENSORS_LIBRARY sensors)
    find_path(SENSORS_INCLUDE_DIR sensors/sensors.h)
    if(SENSORS_LIBRARY AND SENSORS_INCLUDE_DIR)
        set(SENSORS_FOUND TRUE)
        set(SENSORS_LIBRARIES ${SENSORS_LIBRARY})
        set(SENSORS_INCLUDE_DIRS ${SENSORS_INCLUDE_DIR})
    endif()
endif()
pkg_check_modules(UPOWER upower-glib)

# Include directories
include_directories(
    ${GTK3_INCLUDE_DIRS}
    ${CAIRO_INCLUDE_DIRS}
    ${GLIB_INCLUDE_DIRS}
    ${SQLITE3_INCLUDE_DIRS}
    ${CURL_INCLUDE_DIRS}
    ${JSON_GLIB_INCLUDE_DIRS}
    ${CMAKE_SOURCE_DIR}/src
)

# Link directories
link_directories(
    ${GTK3_LIBRARY_DIRS}
    ${CAIRO_LIBRARY_DIRS}
    ${GLIB_LIBRARY_DIRS}
    ${SQLITE3_LIBRARY_DIRS}
    ${CURL_LIBRARY_DIRS}
    ${JSON_GLIB_LIBRARY_DIRS}
)

# Source files
set(COLLECTOR_SOURCES
    src/collectors/cpu_collector.c
    src/collectors/memory_collector.c
    src/collectors/network_collector.c
    src/collectors/disk_collector.c
    src/collectors/gpu_collector.c
    src/collectors/sensors_collector.c
    src/collectors/battery_collector.c
    src/collectors/aitoken_collector.c
    src/collectors/process_collector.c
    src/collectors/tpu_collector.c
)

set(WIDGET_SOURCES
    src/widgets/base_widget.c
    src/widgets/graph_widget.c
    src/widgets/cpu_widget.c
    src/widgets/memory_widget.c
    src/widgets/network_widget.c
    src/widgets/disk_widget.c
    src/widgets/gpu_widget.c
    src/widgets/sensors_widget.c
    src/widgets/battery_widget.c
    src/widgets/aitoken_widget.c
    src/widgets/process_widget.c
    src/widgets/tpu_widget.c
)

set(CORE_SOURCES
    src/core/module_manager.c
    src/core/dataset.c
    src/core/preferences.c
    src/core/utils.c
)

set(UI_SOURCES
    src/ui/main_window.c
    src/ui/preferences_window.c
)

# Main executable
add_executable(xrg-linux
    src/main.c
    ${COLLECTOR_SOURCES}
    ${WIDGET_SOURCES}
    ${CORE_SOURCES}
    ${UI_SOURCES}
)

# Link libraries
target_link_libraries(xrg-linux
    ${GTK3_LIBRARIES}
    ${CAIRO_LIBRARIES}
    ${GLIB_LIBRARIES}
    ${SQLITE3_LIBRARIES}
    ${CURL_LIBRARIES}
    ${JSON_GLIB_LIBRARIES}
    m  # Math library
)

# Optional libraries
if(SENSORS_FOUND)
    target_include_directories(xrg-linux PRIVATE ${SENSORS_INCLUDE_DIRS})
    target_link_libraries(xrg-linux ${SENSORS_LIBRARIES})
    target_compile_definitions(xrg-linux PRIVATE HAVE_SENSORS)
endif()

if(UPOWER_FOUND)
    target_include_directories(xrg-linux PRIVATE ${UPOWER_INCLUDE_DIRS})
    target_link_libraries(xrg-linux ${UPOWER_LIBRARIES})
    target_compile_definitions(xrg-linux PRIVATE HAVE_UPOWER)
endif()

# Core sources without GTK-dependent preferences for CLI test
set(CLI_CORE_SOURCES
    src/core/module_manager.c
    src/core/dataset.c
    src/core/utils.c
)

# CLI Test utility (no GTK GUI, just collectors)
add_executable(xrg-cli-test
    src/tests/cli_test.c
    ${COLLECTOR_SOURCES}
    ${CLI_CORE_SOURCES}
)

# Define to skip preferences in collectors for CLI test
target_compile_definitions(xrg-cli-test PRIVATE XRG_CLI_TEST)

target_link_libraries(xrg-cli-test
    ${GLIB_LIBRARIES}
    ${SQLITE3_LIBRARIES}
    ${CURL_LIBRARIES}
    ${JSON_GLIB_LIBRARIES}
    m
)

# Optional libraries for CLI test
if(SENSORS_FOUND)
    target_include_directories(xrg-cli-test PRIVATE ${SENSORS_INCLUDE_DIRS})
    target_link_libraries(xrg-cli-test ${SENSORS_LIBRARIES})
    target_compile_definitions(xrg-cli-test PRIVATE HAVE_SENSORS)
endif()

if(UPOWER_FOUND)
    target_include_directories(xrg-cli-test PRIVATE ${UPOWER_INCLUDE_DIRS})
    target_link_libraries(xrg-cli-test ${UPOWER_LIBRARIES})
    target_compile_definitions(xrg-cli-test PRIVATE HAVE_UPOWER)
endif()

# Installation
install(TARGETS xrg-linux xrg-cli-test DESTINATION bin)
# Desktop entry + icon are named after the GApplication id so GNOME can
# associate the running window with its launcher
install(FILES data/com.gaucho.xrg-linux.desktop DESTINATION share/applications)
install(FILES data/icons/com.gaucho.xrg-linux.svg DESTINATION share/icons/hicolor/scalable/apps)

# Tests (optional)
option(BUILD_TESTS "Build tests" OFF)
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# Print configuration summary
message(STATUS "")
message(STATUS "XRG-ng for Linux Configuration:")
message(STATUS "  Version: ${PROJECT_VERSION}")
message(STATUS "  C Compiler: ${CMAKE_C_COMPILER}")
message(STATUS "  Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  GTK3: ${GTK3_VERSION}")
message(STATUS "  Cairo: ${CAIRO_VERSION}")
message(STATUS "  Optional dependencies:")
message(STATUS "    lm-sensors: ${SENSORS_FOUND}")
message(STATUS "    UPower: ${UPOWER_FOUND}")
message(STATUS "")

# Project attribution and license accompany the installed executable.
install(FILES "${CMAKE_SOURCE_DIR}/../LICENSE" "${CMAKE_SOURCE_DIR}/../COPYRIGHT"
    "${CMAKE_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md" DESTINATION share/doc/xrg-linux)
