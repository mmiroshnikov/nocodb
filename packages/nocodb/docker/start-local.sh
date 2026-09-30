#!/bin/sh

if [ ! -d "${NC_TOOL_DIR}" ]; then
  mkdir -p "$NC_TOOL_DIR"
fi

# Serve the CE frontend shipped via nc-lib-gui
export NC_GUI_DIST_PATH="${NC_GUI_DIST_PATH:-/usr/src/app/node_modules/nc-lib-gui/lib/dist}"

# Published nc-lib-gui still ships the Cloud CTA; hide it on this CE image.
node -e '
const fs = require("fs");
const p = process.env.NC_GUI_DIST_PATH + "/index.html";
if (!fs.existsSync(p)) process.exit(0);
let html = fs.readFileSync(p, "utf8");
if (html.includes("nc-hide-join-cloud")) process.exit(0);
const style = "<style id=\"nc-hide-join-cloud\">div:has(> a[href*=\"utm_source=OSS\"]){display:none!important}</style>";
html = html.replace("</head>", style + "</head>");
fs.writeFileSync(p, html);
'

node docker/index.js
