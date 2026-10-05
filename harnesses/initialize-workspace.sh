#!/usr/bin/env bash
set -euo pipefail

workspace_root="${1:?usage: initialize-workspace.sh WORKSPACE_ROOT [--skip-linked-folders]}"
managed_begin='<!-- BEGIN WOVEN MATTER MANAGED -->'
managed_end='<!-- END WOVEN MATTER MANAGED -->'

umask 077
mkdir -p "$workspace_root"

# Normalize shipped folder names without overwriting user files or following links.
# Conflicting files/links stay alongside the destination with a .migrated-N suffix.
merge_folder() (
  source=$1 destination=$2
  if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    mv "$source" "$destination"
  elif [ -d "$source" ] && [ ! -L "$source" ] && [ -d "$destination" ] && [ ! -L "$destination" ]; then
    shopt -s dotglob nullglob
    for child in "$source"/*; do
      merge_folder "$child" "$destination/${child##*/}"
    done
    rmdir "$source"
  else
    suffix=1
    while [ -e "$destination.migrated-$suffix" ] || [ -L "$destination.migrated-$suffix" ]; do
      suffix=$((suffix + 1))
    done
    mv "$source" "$destination.migrated-$suffix"
  fi
)

# Remove only the compatibility alias created by earlier Woven Matter versions.
if [ -L "$workspace_root/REPOS" ] && [ "$(readlink "$workspace_root/REPOS")" = Repos ]; then
  rm "$workspace_root/REPOS"
fi
for entry in "$workspace_root"/* "$workspace_root/.scratch"; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=${entry##*/}
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  [ "$name" != .scratch ] || lower=scratch
  case "$lower" in
    repos|databases|guides|plans|research|work_logs|outbox|scratch|skills)
      if [ "$name" != "$lower" ]; then
        # Check the literal name: -e/-ef cannot distinguish casing on macOS,
        # and -ef cannot identify a dangling symlink at all.
        exact_name=false
        for candidate in "$workspace_root"/*; do
          if [ "${candidate##*/}" = "$lower" ]; then exact_name=true; break; fi
        done
        if ! "$exact_name" && { [ -e "$workspace_root/$lower" ] || [ -L "$workspace_root/$lower" ]; }; then
          temporary=$(mktemp -d "$workspace_root/.rename.XXXXXX")
          mv "$entry" "$temporary/entry"
          mv "$temporary/entry" "$workspace_root/$lower"
          rmdir "$temporary"
        else
          merge_folder "$entry" "$workspace_root/$lower"
        fi
      fi ;;
  esac
done

# Keep even an unavailable link intact so Settings can repair its destination.
# Local linked folders are managed independently under the workspace lock.
if [ "${2:-}" != --skip-linked-folders ]; then
  for folder in repos databases; do
    if [ ! -L "$workspace_root/$folder" ]; then mkdir -p "$workspace_root/$folder"; fi
  done
fi
for folder in guides plans research work_logs outbox scratch skills; do
  if [ ! -L "$workspace_root/$folder" ]; then mkdir -p "$workspace_root/$folder"; fi
done

managed_file="$(mktemp)"
trap 'rm -f "$managed_file"' EXIT
cat > "$managed_file" <<'EOF'
<!-- BEGIN WOVEN MATTER MANAGED -->
# Woven Matter Workspace

You are working in a Woven Matter agent workspace.

- Use the WovenMatter CLI to work with the app. Run `wovenmatter help` to see the
  available tools and how to use them. The CLI connection is supplied by this session, and
  commands use its enabled tools and permissions.
- When the user refers to the note or asset they had open, run `wovenmatter context` to
  get the ID captured when they sent that message. Read its contents through the CLI when
  needed.
- Work in the appropriate checkout under `repos/`.
- Put durable guides in `guides/`, plans in `plans/`, research in `research/`, work
  summaries in `work_logs/`, and deliverables in `outbox/`.
- Use `scratch/` for temporary work, experiments, scripts, and other work worth revisiting
  or reusing.
- Use `skills/` for skills shared across harnesses in this workspace. Interpret the user's
  request and context when choosing where to create a skill.
- Store agent-accessible data in `databases/<name>/`. Each database is an ordinary folder.
- `databases/<name>/.wovenmatter/database.json` records optional `none`, `json`, or
  `sqlite` format guidance using schema `wovenmatter.database.v1`. Keep linked JSON files
  and SQLite databases inside their database folder; remote links cannot follow symlinks.

Woven Matter updates this managed section. Add personal instructions outside its markers
to preserve them through updates.
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

chmod 700 "$workspace_root"
for folder in repos databases guides plans research work_logs outbox scratch skills; do
  if [ -d "$workspace_root/$folder" ] && [ ! -L "$workspace_root/$folder" ]; then
    chmod 700 "$workspace_root/$folder"
  fi
done
chmod 600 "$agents_file"
