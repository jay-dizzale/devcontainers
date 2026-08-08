#!/bin/sh
# motd — welcome screen shown on container login.
# Detects installed tools dynamically — only shows what's present.
# All version checks run in parallel so total wait = slowest single tool.

_C='\033[36m'  # cyan
_B='\033[1m'   # bold
_D='\033[2m'   # dim
_G='\033[32m'  # green
_R='\033[0m'   # reset

W1=16   # tool name column (inner width)
W2=22   # version column (inner width)

# ── helpers ───────────────────────────────────────────────────────────────────

_rep() { i=0; while [ "$i" -lt "$2" ]; do printf '%s' "$1"; i=$((i+1)); done; }

_hline() {
    printf " ${_D}${1}"; _rep '─' $((W1+2))
    printf "${2}";        _rep '─' $((W2+2))
    printf "${3}${_R}\n"
}

_row() {
    printf " ${_D}│${_R} ${_G}%-${W1}s${_R} ${_D}│${_R} %-${W2}s ${_D}│${_R}\n" "$1" "$2"
}

# ── parallel version resolution ───────────────────────────────────────────────

_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR"' EXIT

_i=0

# Spawn a background job that writes "name<TAB>version" to a numbered temp file.
# CHECKPOINT_DISABLE=1 prevents tofu/terraform from phoning home on --version.
_tool() {
    _name="$1"; shift
    command -v "$1" >/dev/null 2>&1 || return 0
    _i=$((_i + 1))
    _file="$(printf '%s/%03d' "$_TMPDIR" "$_i")"
    (
        _v="$(CHECKPOINT_DISABLE=1 timeout 5s "$@" 2>&1 \
              | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
        printf '%s\t%s\n' "$_name" "${_v:-?}" > "$_file"
    ) &
}

# ── banner ────────────────────────────────────────────────────────────────────

printf "${_C}${_B}"
printf '  ██████╗ ███████╗██╗   ██╗\n'
printf '  ██╔══██╗██╔════╝██║   ██║\n'
printf '  ██║  ██║█████╗  ██║   ██║\n'
printf '  ██║  ██║██╔══╝  ╚██╗ ██╔╝\n'
printf '  ██████╔╝███████╗ ╚████╔╝ \n'
printf '  ╚═════╝ ╚══════╝  ╚═══╝  \n'
printf "${_R}${_D}                  devcontainer${_R}\n\n"

# ── launch all checks in background ──────────────────────────────────────────

# Languages & runtimes
_tool "go"             go version
_tool "node"           node --version
_tool "java"           java -version
_tool "rustc"          rustc --version
_tool "ruby"           ruby --version
_tool "python3"        python3 --version
_tool "dotnet"         dotnet --version
_tool "gcc"            gcc --version

# Build / package tools
_tool "cargo"          cargo --version
_tool "mvn"            mvn --version
_tool "npm"            npm --version
_tool "uv"             uv --version

# LaTeX
_tool "pdflatex"       pdflatex --version

# IaC
_tool "tofu"           tofu --version
_tool "terraform"      terraform --version
_tool "tenv"           tenv --version
_tool "tflint"         tflint --version
_tool "terraform-docs" terraform-docs --version

# Cloud CLIs
_tool "aws"            aws --version
_tool "az"             az --version
_tool "spacectl"       spacectl version

# Dev tools
_tool "gh"             gh --version
_tool "tea"            tea --version
_tool "snyk"           snyk --version
_tool "claude"         claude --version
_tool "git"            git --version

# Kafka — version lives in the client jar filename (no subprocess needed)
if [ -d /opt/kafka/libs ]; then
    _kv="$(ls /opt/kafka/libs/kafka-clients-*.jar 2>/dev/null \
           | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    printf '%s\t%s\n' "kafka" "${_kv:-?}" > "$(printf '%s/%03d' "$_TMPDIR" $((_i+1)))"
fi

# ── wait for all jobs then print table in original order ──────────────────────

wait

_hline '┌' '┬' '┐'
printf " ${_D}│${_R} ${_B}%-${W1}s${_R} ${_D}│${_R} ${_B}%-${W2}s${_R} ${_D}│${_R}\n" "tool" "version"
_hline '├' '┼' '┤'

for _f in "$_TMPDIR"/[0-9]*; do
    [ -f "$_f" ] || continue
    IFS='	' read -r _n _v < "$_f"
    _row "$_n" "$_v"
done

_hline '└' '┴' '┘'
printf '\n'
