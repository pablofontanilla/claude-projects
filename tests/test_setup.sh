#!/bin/bash
#
# Test suite for setup.sh
# =======================
# Run from the repo root:  bash tests/test_setup.sh
#
# All tests run in isolated temp workspaces and clean up after themselves.
# Requirements: bash 4+, git 2.27+, python3

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOTAL=0 PASSED=0 FAILED=0
_GROUP=""

# ─── Mini test framework ──────────────────────────────────────────────────────

group()   { _GROUP="$1"; echo; echo "── $_GROUP"; }
ok()      { echo "  ✓ $1"; TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); }
fail()    { echo "  ✗ $1${2:+  ($2)}"; TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); }

assert_success() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc" "expected exit 0"; fi
}

assert_failure() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc" "expected non-zero exit"; fi
}

assert_file() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then ok "$desc"; else fail "$desc" "missing: $path"; fi
}

assert_dir() {
    local desc="$1" path="$2"
    if [[ -d "$path" ]]; then ok "$desc"; else fail "$desc" "missing dir: $path"; fi
}

assert_contains() {
    local desc="$1" path="$2" pattern="$3"
    if grep -q "$pattern" "$path" 2>/dev/null; then
        ok "$desc"
    else
        fail "$desc" "pattern '$pattern' not found in $path"
    fi
}

assert_not_contains() {
    local desc="$1" path="$2" pattern="$3"
    if ! grep -q "$pattern" "$path" 2>/dev/null; then
        ok "$desc"
    else
        fail "$desc" "unexpected pattern '$pattern' in $path"
    fi
}

assert_output_contains() {
    local desc="$1" pattern="$2" output="$3"
    if echo "$output" | grep -q "$pattern"; then
        ok "$desc"
    else
        fail "$desc" "pattern '$pattern' not in output"
    fi
}

# ─── Workspace + fixture helpers ─────────────────────────────────────────────

# Create an isolated workspace: copy of setup.sh + presets/ + a bare .git for
# .git/info/exclude support.
new_workspace() {
    local ws
    ws=$(mktemp -d)
    cp "$REPO_ROOT/setup.sh" "$ws/"
    cp -r "$REPO_ROOT/presets" "$ws/"
    git init -q "$ws"
    git -C "$ws" config user.email "test@test.com"
    git -C "$ws" config user.name "Test"
    echo "$ws"
}

cleanup() { rm -rf "$1"; }

# Write a minimal valid preset into a directory.
make_preset_dir() {
    local dir="$1" name="${2:-test-preset}"
    mkdir -p "$dir/context"
    printf 'name: %s\ndescription: "Test preset for automated tests"\n' "$name" \
        > "$dir/preset.yaml"
    printf 'repos:\n  - name: testrepo\n    url: https://example.com/r.git\n    branch: main\n    category: testing\n    summary: "test repo"\n' \
        > "$dir/dev-env.yaml"
    printf '# testrepo — test context (preset: %s)\n' "$name" \
        > "$dir/context/testrepo.md"
}

# Turn a directory into a git repo with a single commit (for file:// cloning).
# Disables commit signing so this works in environments with global signing config.
git_commit_all() {
    local dir="$1"
    git init -q -b main "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config gpg.format openpgp
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "init"
}

# Create a real cloneable git repo with a single file.
make_cloneable_repo() {
    local dir="$1" name="${2:-testrepo}"
    mkdir -p "$dir"
    printf '# %s\n' "$name" > "$dir/README.md"
    git_commit_all "$dir"
}

# Run setup.sh in a workspace (no stdin).
run_setup() {
    local ws="$1"; shift
    bash "$ws/setup.sh" "$@"
}

# Run setup.sh feeding a single answer to a prompt.
run_setup_yn() {
    local ws="$1" answer="$2"; shift 2
    echo "$answer" | bash "$ws/setup.sh" "$@"
}

# ─── Tests ────────────────────────────────────────────────────────────────────

# ── 1. Bundled preset init ────────────────────────────────────────────────────
group "Bundled preset init"

ws=$(new_workspace)

out=$(run_setup "$ws" init 2>&1) || true
assert_output_contains "init (no args) exits 0"         "Available presets"  "$out"
assert_output_contains "init (no args) lists example"   "example"            "$out"
assert_output_contains "init (no args) shows URL hint"  "url"                "$out"

run_setup_yn "$ws" "y" init example >/dev/null 2>&1
assert_file      "init example creates dev-env.yaml"        "$ws/dev-env.yaml"
assert_contains  "preset block: name"                       "$ws/dev-env.yaml" "name: example"
assert_contains  "preset block: source bundled"             "$ws/dev-env.yaml" "source: bundled"
assert_not_contains "no stray scalar preset: line"          "$ws/dev-env.yaml" "^preset: example"

# Re-init with tnf to verify scalar 'preset: tnf' is replaced by the mapping
run_setup_yn "$ws" "y" init tnf >/dev/null 2>&1
assert_contains  "tnf scalar replaced: name"   "$ws/dev-env.yaml" "name: tnf"
assert_contains  "tnf scalar replaced: source" "$ws/dev-env.yaml" "source: bundled"
assert_not_contains "scalar form gone"         "$ws/dev-env.yaml" "^preset: tnf"

cleanup "$ws"

# ── 2. Validation errors ──────────────────────────────────────────────────────
group "Validation errors"

ws=$(new_workspace)

assert_failure "unknown bundled preset name exits non-zero" \
    run_setup "$ws" init does-not-exist

# Preset missing dev-env.yaml
bad_preset="$ws/presets/no-devenv"
mkdir -p "$bad_preset"
printf 'name: no-devenv\n' > "$bad_preset/preset.yaml"
out=$(run_setup "$ws" init no-devenv 2>&1) || true
assert_output_contains "missing dev-env.yaml: error shown" "dev-env.yaml" "$out"
assert_output_contains "missing dev-env.yaml: layout hint shown" "preset.yaml" "$out"

# Preset missing preset.yaml
bad_preset2="$ws/presets/no-presetyaml"
mkdir -p "$bad_preset2"
printf 'repos: []\n' > "$bad_preset2/dev-env.yaml"
out=$(run_setup "$ws" init no-presetyaml 2>&1) || true
assert_output_contains "missing preset.yaml: error shown" "preset.yaml" "$out"

cleanup "$ws"

# ── 3. External preset init (file://) ─────────────────────────────────────────
group "External preset init (file://)"

ws=$(new_workspace)
fixture=$(mktemp -d)
make_preset_dir "$fixture" "ext-preset"
git_commit_all "$fixture"

run_setup_yn "$ws" "y" init "file://$fixture" >/dev/null 2>&1

assert_dir      "external preset installed in presets/"    "$ws/presets/ext-preset"
assert_file     "installed preset has preset.yaml"         "$ws/presets/ext-preset/preset.yaml"
assert_file     "installed preset has dev-env.yaml"        "$ws/presets/ext-preset/dev-env.yaml"
assert_file     "dev-env.yaml created at workspace root"   "$ws/dev-env.yaml"
assert_contains "preset block has source URL"              "$ws/dev-env.yaml" "source: file://$fixture"
assert_contains "preset block has name from preset.yaml"   "$ws/dev-env.yaml" "name: ext-preset"

# .git/info/exclude should have the external preset pattern
assert_contains "external preset added to git exclude" \
    "$ws/.git/info/exclude" "presets/ext-preset/"

cleanup "$ws"
cleanup "$fixture"

# ── 4. External preset — #subdir form ─────────────────────────────────────────
group "External preset pack with #subdir"

ws=$(new_workspace)
pack=$(mktemp -d)

# Pack repo contains two preset subdirs
make_preset_dir "$pack/team-alpha" "team-alpha"
make_preset_dir "$pack/team-beta"  "team-beta"
git_commit_all "$pack"

run_setup_yn "$ws" "y" init "file://$pack#team-alpha" >/dev/null 2>&1

assert_dir      "correct subdir installed"                 "$ws/presets/team-alpha"
assert_file     "subdir preset.yaml present"               "$ws/presets/team-alpha/preset.yaml"
# Wrong subdir should NOT be installed
if [[ ! -d "$ws/presets/team-beta" ]]; then
    ok "other subdir not installed"
else
    fail "other subdir not installed" "team-beta was unexpectedly installed"
fi
assert_contains "subdir recorded in dev-env.yaml"          "$ws/dev-env.yaml" "subdir: team-alpha"

cleanup "$ws"
cleanup "$pack"

# ── 5. External preset — broken layout errors ──────────────────────────────────
group "External preset validation (file://)"

ws=$(new_workspace)

# Pack missing both required files
bad_pack=$(mktemp -d)
echo "just a file" > "$bad_pack/README.md"
git_commit_all "$bad_pack"

out=$(run_setup_yn "$ws" "y" init "file://$bad_pack" 2>&1) || true
assert_output_contains "broken pack: error mentions preset.yaml"  "preset.yaml"  "$out"
assert_output_contains "broken pack: error mentions dev-env.yaml" "dev-env.yaml" "$out"

cleanup "$ws"
cleanup "$bad_pack"

# ── 6. refresh-preset ─────────────────────────────────────────────────────────
group "refresh-preset"

ws=$(new_workspace)

# Without dev-env.yaml — should error
out=$(run_setup "$ws" refresh-preset 2>&1) || true
assert_output_contains "no dev-env.yaml: helpful error" "init" "$out"

# Bundled refresh
run_setup_yn "$ws" "y" init example >/dev/null 2>&1
run_setup_yn "$ws" "y" refresh-preset >/dev/null 2>&1
assert_file     "dev-env.yaml still present after bundled refresh" "$ws/dev-env.yaml"
assert_contains "source still bundled after refresh"               "$ws/dev-env.yaml" "source: bundled"

cleanup "$ws"

# External refresh: modify fixture between init and refresh, verify update applied
ws=$(new_workspace)
fixture=$(mktemp -d)
make_preset_dir "$fixture" "refreshable"
git_commit_all "$fixture"

run_setup_yn "$ws" "y" init "file://$fixture" >/dev/null 2>&1

# Modify the preset (add a new file) and re-commit so there's something to refresh
echo "new_field: added" >> "$fixture/preset.yaml"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m "update preset"

run_setup_yn "$ws" "y" refresh-preset >/dev/null 2>&1
assert_file     "dev-env.yaml present after external refresh"  "$ws/dev-env.yaml"
assert_contains "updated preset.yaml installed"                \
    "$ws/presets/refreshable/preset.yaml" "new_field"

cleanup "$ws"
cleanup "$fixture"

# ── 7. parse_yaml_preset — legacy scalar format ───────────────────────────────
group "parse_yaml_preset backward compat"

ws=$(new_workspace)

# Write a dev-env.yaml with the old scalar form (as the tnf preset still ships)
cat > "$ws/dev-env.yaml" << 'EOF'
preset: example

repos: []
EOF

# refresh-preset reads the preset: block via parse_yaml_preset; if it handles
# the scalar form it will find "example", locate presets/example/, and succeed.
run_setup_yn "$ws" "y" refresh-preset >/dev/null 2>&1
assert_contains "scalar parsed: refresh finds preset name"    "$ws/dev-env.yaml" "name: example"
assert_contains "scalar upgraded to mapping after refresh"    "$ws/dev-env.yaml" "source: bundled"
assert_not_contains "scalar form gone after refresh"          "$ws/dev-env.yaml" "^preset: example"

cleanup "$ws"

# ── 8. Active-preset scoping in clone_repo ────────────────────────────────────
group "clone_repo: context files from active preset only"

ws=$(new_workspace)

# Two presets, both with context for "sharedrepo" — different content
mkdir -p "$ws/presets/alpha/context" "$ws/presets/beta/context"

printf 'name: alpha\ndescription: "Alpha"\n' > "$ws/presets/alpha/preset.yaml"
printf 'name: beta\ndescription: "Beta"\n'   > "$ws/presets/beta/preset.yaml"
printf '# context from ALPHA\n'  > "$ws/presets/alpha/context/sharedrepo.md"
printf '# context from BETA\n'   > "$ws/presets/beta/context/sharedrepo.md"

# Create a tiny cloneable git repo for sharedrepo
shared_src=$(mktemp -d)
make_cloneable_repo "$shared_src" "sharedrepo"

# Write dev-env.yaml with active preset = alpha, pointing at local repo
cat > "$ws/dev-env.yaml" << EOF
preset:
  name: alpha
  source: bundled

repos:
  - name: sharedrepo
    url: file://$shared_src
    branch: main
    category: testing
    summary: "shared test repo"
EOF

run_setup "$ws" clone >/dev/null 2>&1

assert_file     "sharedrepo cloned"                       "$ws/repos/sharedrepo/README.md"
assert_file     "CONTEXT.md distributed"                  "$ws/repos/sharedrepo/CONTEXT.md"
assert_contains "context is from ALPHA (active preset)"   "$ws/repos/sharedrepo/CONTEXT.md" "ALPHA"
assert_not_contains "context is NOT from BETA"            "$ws/repos/sharedrepo/CONTEXT.md" "BETA"

cleanup "$ws"
cleanup "$shared_src"

# ── 8b. context_filename override in preset.yaml ─────────────────────────────
group "clone_repo: context_filename override"

ws=$(new_workspace)

mkdir -p "$ws/presets/custom/context"
# preset declares a custom filename
printf 'name: custom\ndescription: "Custom"\ncontext_filename: MY-CONTEXT.md\n' \
    > "$ws/presets/custom/preset.yaml"
printf '# custom context\n' > "$ws/presets/custom/context/testrepo.md"
printf 'repos:\n  - name: testrepo\n    url: https://example.com/r.git\n    branch: main\n    category: testing\n    summary: "test repo"\n' \
    > "$ws/presets/custom/dev-env.yaml"

shared_src2=$(mktemp -d)
make_cloneable_repo "$shared_src2" "testrepo"

cat > "$ws/dev-env.yaml" << EOF
preset:
  name: custom
  source: bundled

repos:
  - name: testrepo
    url: file://$shared_src2
    branch: main
    category: testing
    summary: "test repo"
EOF

run_setup "$ws" clone >/dev/null 2>&1

assert_file         "MY-CONTEXT.md distributed"                  "$ws/repos/testrepo/MY-CONTEXT.md"
assert_not_contains "default CONTEXT.md not created"             "$ws/repos/testrepo/MY-CONTEXT.md" "CONTEXT.md"
assert_contains     "context content present"                     "$ws/repos/testrepo/MY-CONTEXT.md" "custom context"

cleanup "$ws"
cleanup "$shared_src2"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
echo "──────────────────────────────────────────"
printf "Results: %d passed, %d failed, %d total\n" "$PASSED" "$FAILED" "$TOTAL"
echo "──────────────────────────────────────────"

[[ $FAILED -eq 0 ]]
