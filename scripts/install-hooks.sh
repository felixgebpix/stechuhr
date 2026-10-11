#!/bin/zsh
# Adds the Stechuhr hooks to ~/.claude/settings.json (global for all Claude Code sessions).
# Existing settings are kept; a backup is written first. Running it twice does not add duplicates.
#   scripts/install-hooks.sh            -> install
#   scripts/install-hooks.sh --remove   -> remove the Stechuhr hooks again
set -euo pipefail
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.backup-$(date +%Y%m%d-%H%M%S)"

/usr/bin/python3 - "$SETTINGS" "${1:-}" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
cmd = '"$HOME/Library/Application Support/Stechuhr/bin/stechuhr-hook"'
cfg = json.load(open(path))
hooks = cfg.setdefault("hooks", {})

def is_ours(group):
    return any("stechuhr-hook" in h.get("command", "") for h in group.get("hooks", []))

# Always remove our old entries first, so the script is idempotent.
for event in list(hooks):
    hooks[event] = [g for g in hooks[event] if not is_ours(g)]
    if not hooks[event]:
        del hooks[event]

if mode != "--remove":
    for event in ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "PermissionRequest", "PostToolUse"]:
        hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": cmd, "async": True}]})
    # SessionEnd runs synchronously (async hooks may be cut off at exit); the helper gives up after ~1 s.
    hooks.setdefault("SessionEnd", []).append({"hooks": [{"type": "command", "command": cmd, "timeout": 2}]})

if not hooks:
    del cfg["hooks"]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("Stechuhr-Hooks entfernt." if mode == "--remove" else "Stechuhr-Hooks eingetragen. Sie gelten ab der nächsten Claude-Code-Session.")
PY
