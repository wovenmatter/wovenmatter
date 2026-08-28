#!/usr/bin/env bash
set -euo pipefail

workspace_root="${1:?usage: initialize-workspace.sh WORKSPACE_ROOT}"
managed_begin='<!-- BEGIN WOVEN MATTER MANAGED -->'
managed_end='<!-- END WOVEN MATTER MANAGED -->'

umask 077
mkdir -p "$workspace_root" \
  "$workspace_root/REPOS" \
  "$workspace_root/Databases" \
  "$workspace_root/GUIDES" \
  "$workspace_root/PLANS" \
  "$workspace_root/RESEARCH" \
  "$workspace_root/WORK_LOGS" \
  "$workspace_root/OUTBOX" \
  "$workspace_root/.scratch"

managed_file="$(mktemp)"
trap 'rm -f "$managed_file"' EXIT
cat > "$managed_file" <<'EOF'
<!-- BEGIN WOVEN MATTER MANAGED -->
# Woven Matter Workspace

- Work in the appropriate checkout under `REPOS/`.
- Follow repository-local instructions and preserve unrelated changes.
- Put durable guides, plans, research, work summaries, and deliverables in the matching workspace folders.
- Treat `.scratch/` as disposable and never store credentials in workspace documents.
<!-- END WOVEN MATTER MANAGED -->
EOF

agents_file="$workspace_root/AGENTS.md"
if [ ! -e "$agents_file" ]; then
  cp "$managed_file" "$agents_file"
elif ! grep -Fq "$managed_begin" "$agents_file"; then
  printf '\n' >> "$agents_file"
  cat "$managed_file" >> "$agents_file"
else
  awk -v begin="$managed_begin" -v end="$managed_end" -v managed="$managed_file" '
    $0 == begin {
      while ((getline line < managed) > 0) print line
      close(managed)
      replacing = 1
      next
    }
    replacing && $0 == end { replacing = 0; next }
    !replacing { print }
  ' "$agents_file" > "$agents_file.next"
  mv "$agents_file.next" "$agents_file"
fi

if [ ! -e "$workspace_root/CLAUDE.md" ] && [ ! -L "$workspace_root/CLAUDE.md" ]; then
  ln -s AGENTS.md "$workspace_root/CLAUDE.md"
fi

chmod 700 "$workspace_root" "$workspace_root"/* "$workspace_root/.scratch" 2>/dev/null || true
chmod 600 "$agents_file"
