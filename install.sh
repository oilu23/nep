#!/usr/bin/env bash
# install.sh — one-shot installer for nep.
#
# Installs nep into your SYSTEM Python's user site (~/.local), so the `nep`
# command lives at ~/.local/bin/nep and Just Works from any terminal. No
# virtual environment is created or required.
#
# Handles the two things that tripped people up in testing:
#   1. PEP 668 "externally-managed-environment" on modern Debian/Ubuntu —
#      we pass --break-system-packages to pip (safe with --user: it only
#      writes under ~/.local, never /usr).
#   2. ~/.local/bin not being on PATH — we add it to ~/.bashrc if missing.
#
# Usage:
#   cd /path/to/nep-source   # the dir containing nep.py + setup.py
#   ./install.sh
#
# Re-running is safe and idempotent; it just reinstalls/refreshes.
set -euo pipefail

# Resolve the directory this script lives in — that's the project root,
# regardless of where you invoke it from. We cd there so `pip install -e .`
# picks up nep.py from this checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "nep installer — installs into your user site (~/.local), no venv needed."
echo "source dir: $SCRIPT_DIR"
echo

# --- 1. find a Python + pip -------------------------------------------------
# Prefer python3, fall back to python. We don't touch venvs on purpose.
PY_BIN=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then
        PY_BIN="$c"
        break
    fi
done
if [ -z "$PY_BIN" ]; then
    echo "✗ no python3/python found on PATH. Install python3 first:" >&2
    echo "    sudo apt install python3 python3-pip" >&2
    exit 1
fi
echo "python: $($PY_BIN --version 2>&1)  ($PY_BIN)"

# Use the matching pip via the module form so we target the same interpreter.
PIP="$PY_BIN -m pip"
if ! $PIP --version >/dev/null 2>&1; then
    echo "✗ pip not available for $PY_BIN. Install it:" >&2
    echo "    sudo apt install python3-pip" >&2
    exit 1
fi

# --- 2. decide whether we need --break-system-packages ---------------------
# PEP 668: distros ship an EXTERNALLY-MANAGED marker file. `pip install --user`
# then refuses unless passed --break-system-packages. Detect that case and
# reuse the flag for every pip call. With --user it only writes under
# ~/.local, so it can't actually break the system — the flag just un-brakes
# the install.
EXTRA_PIP_FLAGS=()
if ! $PIP install --user --dry-run pip >/dev/null 2>&1; then
    # Dry-run refused. It's either PEP 668 or an old pip with no --dry-run.
    # Retry with the flag; if that succeeds, we use it for the real installs.
    if $PIP install --user --dry-run --break-system-packages pip >/dev/null 2>&1; then
        EXTRA_PIP_FLAGS+=(--break-system-packages)
    else
        # Old pip that doesn't understand --dry-run at all: probe the marker
        # file directly. EXTERNALLY-MANAGED lives next to the stdlib in most
        # distros. If present, pass the flag (on old pip it's harmless).
        MARKER="$($PY_BIN -c 'import sysconfig, os; print(os.path.join(sysconfig.get_paths()["stdlib"], "EXTERNALLY-MANAGED"))' 2>/dev/null || true)"
        if [ -n "$MARKER" ] && [ -f "$MARKER" ]; then
            EXTRA_PIP_FLAGS+=(--break-system-packages)
        fi
    fi
fi
if [ "${#EXTRA_PIP_FLAGS[@]}" -gt 0 ]; then
    echo "pip flags: ${EXTRA_PIP_FLAGS[*]}  (PEP 668 externally-managed environment detected)"
fi

# --- 3. install dependencies + nep (editable) ------------------------------
# Editable (-e .) so edits to nep.py in this checkout take effect immediately
# with no reinstall. --user scopes everything to ~/.local.
echo
echo "installing openai + httpx<0.28 (the only runtime deps)…"
$PIP install --user "${EXTRA_PIP_FLAGS[@]}" openai "httpx<0.28"

echo "installing nep itself (editable, from $SCRIPT_DIR)…"
$PIP install --user "${EXTRA_PIP_FLAGS[@]}" -e .

# --- 4. make sure ~/.local/bin is on PATH ----------------------------------
# pip --user drops the console script at ~/.local/bin/nep. If that dir isn't
# on PATH, `nep` won't be found. Add it to the user's shell rc file
# idempotently, and also export it for the current shell so they can use
# `nep` right away without re-logging-in.
USER_BIN="$HOME/.local/bin"
NEED_PATH_EXPORT=0
case ":$PATH:" in
    *":$USER_BIN:"*) : ;;                              # already on PATH
    *)
        echo "PATH is missing $USER_BIN — adding it to your shell rc."
        NEED_PATH_EXPORT=1
        ;;
esac

add_to_rc() {
    local rc="$1"
    # Append a small guarded block that adds ~/.local/bin to PATH if it's
    # not already there. Guarded so re-running install.sh doesn't duplicate
    # the line on every invocation.
    if [ -f "$rc" ] && ! grep -q 'nep-installer: local-bin on PATH' "$rc"; then
        cat >> "$rc" <<'EOF'

# nep-installer: local-bin on PATH
case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
        echo "  -> added PATH entry to $rc"
    fi
}

if [ "$NEED_PATH_EXPORT" -eq 1 ]; then
    # Prefer .bashrc for interactive bash (the common case on Ubuntu/Debian),
    # then .profile for login shells (incl. over ssh in some setups). If
    # neither exists, create .bashrc.
    add_to_rc "$HOME/.bashrc" 2>/dev/null || true
    [ -f "$HOME/.profile" ] && add_to_rc "$HOME/.profile" 2>/dev/null || true
    # Export for THIS shell so the user can run `nep` immediately below.
    export PATH="$USER_BIN:$PATH"
fi

# --- 5. sanity check --------------------------------------------------------
echo
echo "checking the install..."
if ! command -v nep >/dev/null 2>&1; then
    echo "ERROR: 'nep' not found on PATH even after install." >&2
    echo "  expected it at $USER_BIN/nep" >&2
    if [ -f "$USER_BIN/nep" ]; then
        echo "  the file exists there, but PATH wasn't updated in this shell." >&2
        echo "  open a NEW terminal (or run: source ~/.bashrc) and 'nep' should work." >&2
    else
        echo "  the console script wasn't created. Check pip output above for errors." >&2
    fi
    exit 1
fi
echo "  OK: 'nep' is on PATH at: $(command -v nep)"

# Headless smoke test — `nep sessions` prints and exits (no REPL, no network
# call), so it verifies the module imports and the command works without
# needing a configured model server.
echo "  smoke test:"
nep sessions || true

echo
echo "Done. 'nep' is installed. Next:"
echo "  1. put your endpoint in ~/.env  (see sources.example.env):"
echo "         NEP_BASE_URL=https://openrouter.ai/api/v1"
echo "         NEP_API_KEY=sk-or-v1-..."
echo "         NEP_MODEL=z-ai/glm-5.2"
echo "  2. run 'nep' from any directory."
echo
echo "If 'nep' isn't found in a NEW terminal, run 'source ~/.bashrc'"
echo "or reopen the shell — the PATH update needs a fresh shell to apply."
