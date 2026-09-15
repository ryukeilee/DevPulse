#!/usr/bin/env bash
set -euo pipefail

devpulse_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$devpulse_root/DevPulseNative/DevPulseNative.xcodeproj/project.pbxproj"

python3 - "$project_file" <<'PY'
import os
import sys
from pathlib import Path

project_file = Path(sys.argv[1])
source_text = project_file.read_text(encoding="utf-8")
malformed = 'SystemCapabilities = "[\\"com.apple.ApplicationGroups\\": [\\"enabled\\": 1]]";'
capability_indent = ""
group_indent = "\t" * 7
enabled_indent = "\t" * 8
closing_indent = "\t" * 6
correct = (
    capability_indent + "SystemCapabilities = {\n"
    + group_indent + "com.apple.ApplicationGroups = {\n"
    + enabled_indent + "enabled = 1;\n"
    + group_indent + "};\n"
    + closing_indent + "};"
)

malformed_count = source_text.count(malformed)
correct_count = source_text.count(correct)

if malformed_count == 2:
    output_text = source_text.replace(malformed, correct)
elif malformed_count == 0 and correct_count == 2:
    output_text = source_text
else:
    raise SystemExit(
        "预期找到两个 XcodeGen App Groups capability 属性；"
        f"实际发现 {malformed_count} 个未修正项、{correct_count} 个已修正项。"
    )

if output_text.count(correct) != 2:
    raise SystemExit("App Groups capability 修正后未生成两个 PBX 字典。")

if output_text != source_text:
    temporary_file = project_file.with_name(project_file.name + ".tmp")
    temporary_file.write_text(output_text, encoding="utf-8")
    temporary_file.chmod(project_file.stat().st_mode)
    os.replace(temporary_file, project_file)
PY
