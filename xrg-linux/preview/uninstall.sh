#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
set -eu
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$bundle/integration.py" uninstall "$@"
