/**
 * Carrying a bot's own system changes to a new base image (a move or a rebuild). The bot's storage
 * already holds its files, home folder, browser profile and restart list; this covers what it
 * changed in the container itself, which a new container would otherwise lose:
 *
 * - `BASELINE` records what the old base image itself had, in a short-lived container of it.
 * - `CAPTURE` runs in a short-lived container of the bot's snapshot (its whole old filesystem) and
 *   writes the difference to the bot's storage: apt packages it marked manual, files it added or
 *   changed under the carried roots (apt sources and keys included) that no package owns as is,
 *   global npm and system pip packages by name and version, and (once, for bots from before the
 *   home folder moved into storage) its home folder.
 * - `REAPPLY` runs as root in the new container: sources and keys, then the apt packages, then the
 *   files, then npm and pip reinstalls (so native code is rebuilt for the new Node and Python),
 *   then the bot's own `/workspace/.woven/setup.sh`. Every step is best effort and the report says
 *   what did not come across; the update fails only if the bot's health check does.
 *
 * Scripts are POSIX sh with Ubuntu's coreutils, findutils, tar and dpkg: they run in old images
 * too, which have no Node at a known path. They treat everything they read as data.
 */

export const SYSTEM_DIR = "/workspace/.woven/system";
export const CARRY_DIR = `${SYSTEM_DIR}/carry`;
export const BASELINE_DIR = `${SYSTEM_DIR}/.baseline`;
export const REPORT_PATH = `${SYSTEM_DIR}/update-report.md`;
/** Present while captured changes wait to be applied (a move that stopped partway resumes them). */
export const PENDING_MARKER = `${CARRY_DIR}/.pending`;
export const SETUP_SCRIPT = "/workspace/.woven/setup.sh";
export const HOME_DIR = "/workspace/.woven/home";

/** Roots whose added or changed files are carried. */
const ROOTS = "/etc /usr/local /opt /usr/share/keyrings /var/spool/cron";

/**
 * Never carried: the runtime's own mounts and links, the old in-image toolchain, generated or
 * identity files, and what is reinstalled by name instead (npm and pip packages).
 */
const PRUNE = [
  "/opt/woven",
  "/opt/woven-bot",
  "/opt/woven-toolchain",
  "/opt/ms-playwright",
  "/opt/wovenmatter",
  "/usr/local/lib/node_modules",
  "/usr/local/lib/python3*",
  "/usr/local/include/node",
  "/usr/local/share/doc/node",
  "/etc/ssl/certs",
  "/etc/alternatives",
  "/etc/passwd",
  "/etc/passwd-",
  "/etc/shadow",
  "/etc/shadow-",
  "/etc/group",
  "/etc/group-",
  "/etc/gshadow",
  "/etc/gshadow-",
  "/etc/subuid",
  "/etc/subgid",
  "/etc/sudoers",
  "/etc/sudoers.d/bot",
  "/etc/hostname",
  "/etc/hosts",
  "/etc/resolv.conf",
  "/etc/mtab",
  "/etc/machine-id",
  "/etc/ld.so.cache",
  "/etc/.pwd.lock",
  "/etc/apt/sources.list.d/ubuntu.sources",
  // Generated from the installed packages; a new release regenerates its own.
  "/etc/ca-certificates.conf",
  "/etc/pam.d/common-*",
  "/etc/shells",
  "/etc/ld.so.conf.d/*.conf.dpkg-*",
];

/** Old in-image toolchain files at /usr/local's top (never the bot's own). */
const LEGACY_FILES = [
  "/usr/local/bin/node",
  "/usr/local/bin/npm",
  "/usr/local/bin/npx",
  "/usr/local/bin/corepack",
  "/usr/local/bin/playwright",
  "/usr/local/CHANGELOG.md",
  "/usr/local/LICENSE",
  "/usr/local/README.md",
  "/usr/local/share/man/man1/node.1",
];

const pruneExpression = PRUNE.map((path) => `-path '${path}'`).join(" -o ");

/**
 * Sorted manifest lines under the roots: `md5  path` for files, `link:<target>  path` for links,
 * `dir:<mode>:<uid>:<gid>  path` for directories (so a directory the bot made or handed to itself
 * comes back with its owner and mode).
 */
const MANIFEST = `manifest() {
  find ${ROOTS} \\( ${pruneExpression} \\) -prune -o -type f -print0 2>/dev/null | xargs -0 -r md5sum 2>/dev/null
  find ${ROOTS} \\( ${pruneExpression} \\) -prune -o -type l -printf 'link:%l  %p\\n' 2>/dev/null
  find ${ROOTS} -mindepth 1 \\( ${pruneExpression} \\) -prune -o -type d -printf 'dir:%m:%U:%G  %p\\n' 2>/dev/null
}`;

/** Root-made directories in the bot's storage stay the bot's (its supervisor and home live there). */
const OWN_STATE = `[ -d /workspace/.woven ] || install -d -o 1000 -g 1000 /workspace/.woven
install -d -o 1000 -g 1000 ${SYSTEM_DIR}`;

/** Run in a container of the old base image, root, no network; writes ${BASELINE_DIR}. */
export const BASELINE = `set -u
export LC_ALL=C
${OWN_STATE}
out=${BASELINE_DIR}
rm -rf "$out"; mkdir -p "$out"
${MANIFEST}
apt-mark showmanual 2>/dev/null | sort -u > "$out/apt-manual.txt"
manifest | sort -u > "$out/files.txt"
ls /usr/local/lib/node_modules 2>/dev/null | sort -u > "$out/npm-global.txt"
`;

/**
 * Run in a container of the bot's snapshot, root, no network, with the bot's storage; writes
 * ${CARRY_DIR} (and moves a pre-storage home folder into storage, once). Exits non-zero, so the
 * update rolls back, when something it must keep (the home folder, the saved files) failed.
 */
export const CAPTURE = `set -u
export LC_ALL=C
${OWN_STATE}
base=${BASELINE_DIR}
out=${CARRY_DIR}
rm -rf "$out"; mkdir -p "$out"
${MANIFEST}
# The home folder moved into storage; a bot from before still has it in its container.
if [ -d /home/bot ] && [ ! -L /home/bot ] && [ ! -e ${HOME_DIR} ]; then
  rm -rf ${HOME_DIR}.new && mkdir -p ${HOME_DIR}.new && cp -a /home/bot/. ${HOME_DIR}.new/ \\
    && rm -rf ${HOME_DIR}.new/.cache && chown 1000:1000 ${HOME_DIR}.new && mv ${HOME_DIR}.new ${HOME_DIR} \\
    || { echo "copying the home folder into storage failed" >&2; rm -rf ${HOME_DIR}.new; exit 1; }
  echo "home" > "$out/home-migrated"
fi
touch "$base/apt-manual.txt" "$base/files.txt" "$base/npm-global.txt"
apt-mark showmanual 2>/dev/null | sort -u | comm -23 - "$base/apt-manual.txt" > "$out/apt-packages.txt"
# What packages installed: their files with dpkg's checksums (so an unchanged one matches and is
# not the bot's, but one the bot edited is), and every path they list (links and directories
# that dpkg made are never the bot's).
{
  cat /var/lib/dpkg/info/*.md5sums 2>/dev/null | awk '{ h = $1; $1 = ""; sub(/^ +/, ""); print h "  /" $0 }'
  dpkg-query -W -f='\${Conffiles}\\n' 2>/dev/null | awk 'NF >= 2 { print $2 "  " $1 }'
} | sort -u > "$out/.owned"
# (Never empty: awk reads its first file as the set.)
{ echo /; cat /var/lib/dpkg/info/*.list 2>/dev/null; } | sort -u > "$out/.listed"
manifest | sort -u | comm -23 - "$base/files.txt" | comm -23 - "$out/.owned" \\
  | awk 'NR == FNR { listed[$0] = 1; next }
         { kind = $1; path = substr($0, index($0, "  ") + 2)
           if ((kind ~ /^link:/ || kind ~ /^dir:/) && (path in listed)) next
           print path }' "$out/.listed" - > "$out/.changed"
grep -vxF -e '${LEGACY_FILES.join("' -e '")}' "$out/.changed" > "$out/files.txt" || true
rm -f "$out/.owned" "$out/.listed" "$out/.changed"
if [ -s "$out/files.txt" ]; then
  tr '\\n' '\\0' < "$out/files.txt" | tar --null --no-recursion --numeric-owner -cpf "$out/files.tar" -T - \\
    || { echo "saving the bot's system files failed" >&2; exit 1; }
  tar -tf "$out/files.tar" | grep -cv '/$' > "$out/files-count.txt" || true
fi
# Global npm packages the bot added (root's, in /usr/local), by name@version.
for dir in /usr/local/lib/node_modules/* /usr/local/lib/node_modules/@*/*; do
  [ -f "$dir/package.json" ] || continue
  name=\${dir#/usr/local/lib/node_modules/}
  case "$name" in npm|corepack|playwright) continue ;; esac
  grep -qxF "$name" "$base/npm-global.txt" && continue
  version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$dir/package.json" | head -n 1)
  echo "$name@$version"
done > "$out/npm-global.txt"
# System pip packages (sudo pip into /usr/local), by name==version from their dist-info.
for info in /usr/local/lib/python3*/dist-packages/*.dist-info; do
  [ -d "$info" ] || continue
  meta="$info/METADATA"
  name=$(sed -n 's/^Name: //p' "$meta" 2>/dev/null | head -n 1)
  version=$(sed -n 's/^Version: //p' "$meta" 2>/dev/null | head -n 1)
  [ -n "$name" ] && [ -n "$version" ] && echo "$name==$version"
done > "$out/pip-system.txt"
python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' > "$out/python.txt" 2>/dev/null || true
rm -rf "$base"
touch ${PENDING_MARKER}
exit 0
`;

/** Root's npm and caches stay out of the bot's cache folder (root-owned files would break its npm). */
const ROOT_ENV = `export NPM_CONFIG_PREFIX=/usr/local NPM_CONFIG_CACHE=/root/.npm XDG_CACHE_HOME=/root/.cache DEBIAN_FRONTEND=noninteractive`;

/** Run as root in the new container, with network. Writes ${REPORT_PATH}; always exits 0. */
export const REAPPLY = `set -u
carry=${CARRY_DIR}
report=${REPORT_PATH}
notes=$(mktemp)
note() { printf '%s\\n' "$*" >> "$notes"; }
count() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
${ROOT_ENV}
restored=0
if [ -d "$carry" ]; then
  # Package sources and keys first, so the packages they provide install.
  if [ -s "$carry/files.tar" ]; then
    tar --numeric-owner -xpf "$carry/files.tar" -C / --wildcards 'etc/apt/*' 'usr/share/keyrings/*' 2>/dev/null || true
  fi
  if [ -s "$carry/apt-packages.txt" ]; then
    apt-get update -q > /dev/null 2>&1 || note "- apt-get update failed; package installs may be incomplete."
    if ! apt-get install -y -q --no-install-recommends $(cat "$carry/apt-packages.txt") > /dev/null 2>&1; then
      for package in $(cat "$carry/apt-packages.txt"); do
        apt-get install -y -q --no-install-recommends "$package" > /dev/null 2>&1 \\
          || note "- The apt package \\\`$package\\\` could not be installed on this image."
      done
    fi
    rm -rf /var/lib/apt/lists/*
  fi
  if [ -s "$carry/files.tar" ]; then
    if tar --numeric-owner -xpf "$carry/files.tar" -C / 2>/dev/null; then restored=$(cat "$carry/files-count.txt" 2>/dev/null || echo 0)
    else note "- Some saved system files could not be restored; they are in $carry/files.tar."; fi
    update-ca-certificates > /dev/null 2>&1 || true
    ldconfig > /dev/null 2>&1 || true
  fi
  if [ -s "$carry/npm-global.txt" ]; then
    while read -r spec; do
      [ -n "$spec" ] || continue
      npm install -g --no-audit --no-fund "$spec" > /dev/null 2>&1 || note "- The global npm package \\\`$spec\\\` could not be reinstalled."
    done < "$carry/npm-global.txt"
  fi
  if [ -s "$carry/pip-system.txt" ]; then
    while read -r spec; do
      [ -n "$spec" ] || continue
      python3 -m pip install -q --break-system-packages "$spec" > /dev/null 2>&1 \\
        || note "- The system pip package \\\`$spec\\\` could not be reinstalled."
    done < "$carry/pip-system.txt"
  fi
  old_python=$(cat "$carry/python.txt" 2>/dev/null || true)
  new_python=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
  if [ -n "$old_python" ] && [ "$old_python" != "$new_python" ] && [ -d /home/bot/.local/lib/python$old_python ]; then
    note "- Python changed from $old_python to $new_python: reinstall your \\\`pip install --user\\\` packages (they are in ~/.local/lib/python$old_python)."
  fi
fi
setup=""
if [ -f ${SETUP_SCRIPT} ]; then
  # Its own shebang when it is executable; bash otherwise.
  if [ -x ${SETUP_SCRIPT} ]; then run_setup() { timeout 1800 ${SETUP_SCRIPT}; }; else run_setup() { timeout 1800 bash ${SETUP_SCRIPT}; }; fi
  if (cd /workspace && run_setup) > ${SYSTEM_DIR}/setup.log 2>&1; then setup="ran"
  else setup="failed"; note "- Your setup script (${SETUP_SCRIPT}) exited with an error; its output is in ${SYSTEM_DIR}/setup.log."; fi
fi
native=$(find /workspace -maxdepth 7 \\( -path /workspace/.woven -prune \\) -o \\( -name '*.node' -path '*/node_modules/*' -o -name pyvenv.cfg \\) -print 2>/dev/null \\
  | sed -e 's#/node_modules/.*#/node_modules#' -e 's#/pyvenv.cfg$##' | sort -u | head -n 20)
mkdir -p ${SYSTEM_DIR}
{
  echo "# Your container moved to a new image"
  echo
  echo "Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
  echo "Everything in /workspace and your home folder stayed. Carried over from your previous container:"
  echo
  echo "- apt packages reinstalled: $(count "$carry/apt-packages.txt")"
  echo "- system files restored (under /etc, /usr/local, /opt, keyrings, crontabs): $restored"
  echo "- global npm packages reinstalled: $(count "$carry/npm-global.txt")"
  echo "- system pip packages reinstalled: $(count "$carry/pip-system.txt")"
  [ -f "$carry/home-migrated" ] && echo "- your home folder moved into your storage (it now persists through every update)"
  [ "$setup" = ran ] && echo "- your setup script ran"
  echo
  echo "The lists are in $carry. Anything installed elsewhere outside /workspace and your home"
  echo "folder was not carried; add it to ${SETUP_SCRIPT} (run as root after each move) to keep it."
  if [ -s "$notes" ]; then echo; echo "## Needs attention"; echo; cat "$notes"; fi
  if [ -n "$native" ]; then
    echo
    echo "## Check these if Node or Python changed"
    echo
    echo "These contain compiled modules or Python environments that may need reinstalling:"
    echo
    printf '%s\\n' "$native" | sed 's/^/- /'
  fi
} > "$report.new" && mv "$report.new" "$report"
rm -f ${PENDING_MARKER}
chown -R 1000:1000 ${SYSTEM_DIR} /var/cache/bot 2>/dev/null || true
rm -f "$notes"
exit 0
`;

/** Run as the bot user after its toolchain changed in place: rebuild its own global npm packages. */
export const REBUILD_USER_PACKAGES = `if [ -d "$HOME/.local/lib/node_modules" ] && [ -n "$(ls -A "$HOME/.local/lib/node_modules" 2>/dev/null)" ]; then
  npm rebuild -g > /dev/null 2>&1 || {
    mkdir -p ${SYSTEM_DIR}
    printf '# Your tools were updated\\n\\nNode or Playwright changed, and rebuilding your global npm packages (~/.local) failed. Reinstall them with npm install -g.\\n' > ${REPORT_PATH}
  }
fi
exit 0`;

/** Run as root after the toolchain changed in place: rebuild root's global npm packages (sudo npm -g). */
export const REBUILD_SYSTEM_PACKAGES = `${ROOT_ENV}
if [ -n "$(ls /usr/local/lib/node_modules 2>/dev/null)" ]; then
  npm rebuild -g > /dev/null 2>&1 || {
    mkdir -p ${SYSTEM_DIR}
    printf '# Your tools were updated\\n\\nNode changed, and rebuilding the global npm packages in /usr/local failed. Reinstall them with sudo npm install -g.\\n' > ${REPORT_PATH}
    chown -R 1000:1000 ${SYSTEM_DIR}
  }
fi
exit 0`;

/**
 * Launch the toolchain's Chromium once, as the bot user, from the toolchain's own browser folder
 * (the bot's PLAYWRIGHT_BROWSERS_PATH is writable for its own Playwright versions).
 */
export const CHROMIUM_PROBE = `PLAYWRIGHT_BROWSERS_PATH="$WOVEN_PLAYWRIGHT_BROWSERS" node -e 'require(process.env.WOVEN_PLAYWRIGHT_MODULE).chromium.launch().then((b) => b.close()).then(() => process.exit(0), (e) => { console.error(String(e && e.message || e).slice(0, 400)); process.exit(1); })'`;

/** Install Chromium's system libraries for the toolchain's Playwright, as root. */
export const CHROMIUM_DEPS = `node "$WOVEN_PLAYWRIGHT_MODULE/cli.js" install-deps chromium && rm -rf /var/lib/apt/lists/*`;
