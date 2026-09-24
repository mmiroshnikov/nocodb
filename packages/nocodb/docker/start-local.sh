#!/bin/sh

if [ ! -d "${NC_TOOL_DIR}" ]; then
  mkdir -p "$NC_TOOL_DIR"
fi

# Serve the CE frontend shipped via nc-lib-gui
export NC_GUI_DIST_PATH="${NC_GUI_DIST_PATH:-/usr/src/app/node_modules/nc-lib-gui/lib/dist}"

node docker/index.js
