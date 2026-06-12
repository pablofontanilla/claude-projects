#!/bin/bash
#
# Dev Environment Setup Script
# ============================
#
# Usage:
#   ./setup.sh              # Clone all repos (first time setup)
#   ./setup.sh clone        # Clone all repos
#   ./setup.sh update       # Update all repos (git pull)
#   ./setup.sh clone <dir>  # Clone specific repo by directory name
#   ./setup.sh update <dir> # Update specific repo by directory name
#   ./setup.sh status       # Show status of all repos
#   ./setup.sh list         # List configured repos
#   ./setup.sh init <name>            # Initialize from a bundled preset
#   ./setup.sh init <url>             # Initialize from an external preset git URL
#   ./setup.sh init <url#subdir>      # External pack repo containing multiple presets
#   ./setup.sh refresh-preset         # Re-fetch preset from its recorded source
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repos"
DEV_ENV_YAML="$SCRIPT_DIR/dev-env.yaml"
DEV_ENV_TEMPLATE="$SCRIPT_DIR/dev-env.yaml.template"
PRESETS_DIR="$SCRIPT_DIR/presets"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── YAML Parsing ─────────────────────────────────────────────────────────────
# Parse dev-env.yaml into pipe-separated lines: url|directory|branch|name|category|summary
# Uses yq if available, falls back to python3 with PyYAML.

parse_yaml_repos() {
    local yaml_file="$1"

    if command -v yq &>/dev/null; then
        yq -r '.repos[] | [.url, (.directory // .name), .branch, .name, .category, .summary] | join("|")' "$yaml_file" 2>/dev/null
        return $?
    fi

    if python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import yaml, sys
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
for r in data.get('repos', []):
    print('|'.join([
        r.get('url',''), r.get('directory', r.get('name','')), r.get('branch','main'),
        r.get('name',''), r.get('category',''), r.get('summary','')
    ]))
" 2>/dev/null
        return $?
    fi

    log_error "Cannot parse dev-env.yaml: no YAML parser available."
    log_info "Install one of the following:"
    log_info "  yq          — https://github.com/mikefarah/yq"
    log_info "  python3-pyyaml — dnf install python3-pyyaml  (or pip install pyyaml)"
    return 1
}

# Read the preset: block from dev-env.yaml.
# Outputs: name|source|ref|subdir (empty string for missing fields)
parse_yaml_preset() {
    local yaml_file="${1:-$DEV_ENV_YAML}"

    if python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import yaml
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
p = data.get('preset', {})
if isinstance(p, str):
    p = {'name': p, 'source': 'bundled'}
elif not isinstance(p, dict):
    p = {}
print('|'.join([
    p.get('name',''), p.get('source','bundled'), p.get('ref',''), p.get('subdir','')
]))
" 2>/dev/null
        return 0
    fi

    if command -v yq &>/dev/null; then
        local name source ref subdir
        name=$(yq -r '(.preset.name // .preset) // ""' "$yaml_file" 2>/dev/null)
        source=$(yq -r '.preset.source // "bundled"' "$yaml_file" 2>/dev/null)
        ref=$(yq -r '.preset.ref // ""' "$yaml_file" 2>/dev/null)
        subdir=$(yq -r '.preset.subdir // ""' "$yaml_file" 2>/dev/null)
        echo "${name}|${source}|${ref}|${subdir}"
        return 0
    fi

    echo "|||"
}

# ─── Repo Source Detection ────────────────────────────────────────────────────
# Verifies dev-env.yaml exists, sets REPO_SOURCE and ACTIVE_PRESET_NAME.

REPO_SOURCE=""
ACTIVE_PRESET_NAME=""

detect_repo_source() {
    if [[ -f "$DEV_ENV_YAML" ]]; then
        REPO_SOURCE="$DEV_ENV_YAML"
        local preset_info
        preset_info=$(parse_yaml_preset "$DEV_ENV_YAML")
        ACTIVE_PRESET_NAME="${preset_info%%|*}"
    else
        log_error "No repo configuration found!"
        log_info "Options:"
        log_info "  ./setup.sh init <preset>  — Initialize from a bundled preset"
        log_info "  ./setup.sh init <url>     — Initialize from an external preset git URL"
        log_info "  cp dev-env.yaml.template dev-env.yaml  — Start from template"
        exit 1
    fi
}

# ─── Line Iteration ──────────────────────────────────────────────────────────
# Iterates over repos from dev-env.yaml, calling a callback with:
#   url, dir, branch (set as globals for backward compat)

iterate_repos() {
    local callback="$1"

    while IFS='|' read -r url dir branch _name _cat _summary; do
        if [[ -z "$url" || -z "$dir" ]]; then
            [[ -n "$_name" || -n "$url" ]] && log_warn "Skipping entry with missing url or name: ${_name:-${url:-unknown}}"
            continue
        fi
        "$callback"
    done < <(parse_yaml_repos "$REPO_SOURCE")
}

# ─── Clone / Update ──────────────────────────────────────────────────────────

# Clone a single repository (blobless clone for faster downloads)
clone_repo() {
    local url="$1"
    local dir="$2"
    local branch="$3"

    local target="$REPOS_DIR/$dir"

    if [[ -d "$target/.git" ]]; then
        log_warn "$dir already exists, skipping (use 'update' to pull)"
        return 0
    fi

    mkdir -p "$REPOS_DIR"

    log_info "Cloning $dir (blobless)..."
    git clone --filter=blob:none --branch "$branch" "$url" "$target"
    log_success "Cloned $dir (branch: $branch)"

    # Distribute context/supplemental files from the active preset only.
    # Scoping to the active preset prevents collisions when multiple installed
    # presets contain files for a same-named repository.
    if [[ -n "$ACTIVE_PRESET_NAME" && -d "$PRESETS_DIR/$ACTIVE_PRESET_NAME" ]]; then
        local preset_base="$PRESETS_DIR/$ACTIVE_PRESET_NAME"

        # Read context_filename from preset.yaml; default to CONTEXT.md
        local ctx_filename="CONTEXT.md"
        if [[ -f "$preset_base/preset.yaml" ]]; then
            local _cf
            _cf=$(python3 -c "
import yaml
with open('$preset_base/preset.yaml') as f:
    d = yaml.safe_load(f)
print(d.get('context_filename', 'CONTEXT.md'))
" 2>/dev/null)
            [[ -n "$_cf" ]] && ctx_filename="$_cf"
        fi

        if [[ -f "$preset_base/context/$dir.md" ]]; then
            cp "$preset_base/context/$dir.md" "$target/$ctx_filename"
            log_info "  Added $ctx_filename"
        fi

        if [[ ! -f "$target/CLAUDE.md" && -f "$preset_base/supplemental/$dir.md" ]]; then
            cp "$preset_base/supplemental/$dir.md" "$target/CLAUDE.md"
            log_info "  Added supplemental CLAUDE.md"
        fi
    fi
}

# Update a single repository
update_repo() {
    local dir="$1"
    local target="$REPOS_DIR/$dir"

    if [[ ! -d "$target/.git" ]]; then
        log_warn "$dir not cloned yet, skipping"
        return 0
    fi

    log_info "Updating $dir..."

    cd "$target"

    if ! git diff --quiet HEAD 2>/dev/null; then
        log_warn "  $dir has local changes, stashing..."
        git stash
    fi

    git pull --rebase
    cd "$SCRIPT_DIR"

    log_success "Updated $dir"
}

# Clone all repositories
clone_all() {
    log_info "Cloning all repositories..."
    echo

    _clone_callback() {
        clone_repo "$url" "$dir" "$branch"
    }
    iterate_repos _clone_callback

    echo
    log_success "All repositories cloned!"
}

# Update all repositories
update_all() {
    log_info "Updating all repositories..."
    echo

    _update_callback() {
        if [[ -d "$REPOS_DIR/$dir/.git" ]]; then
            update_repo "$dir"
        fi
    }
    iterate_repos _update_callback

    echo
    log_success "All repositories updated!"
}

# Clone or update a specific repo
handle_specific_repo() {
    local action="$1"
    local target_dir="$2"
    local found=false

    _find_callback() {
        if [[ "$dir" == "$target_dir" ]]; then
            found=true
            if [[ "$action" == "clone" ]]; then
                clone_repo "$url" "$dir" "$branch"
            else
                update_repo "$dir"
            fi
        fi
    }
    iterate_repos _find_callback

    if [[ "$found" == "false" ]]; then
        log_error "Repository '$target_dir' not found in $REPO_SOURCE"
        echo "Available repositories:"
        list_repos
        exit 1
    fi
}

# ─── Status / List ───────────────────────────────────────────────────────────

# Show status of all repos
show_status() {
    log_info "Repository status:"
    echo
    printf "%-30s %-12s %-20s %s\n" "DIRECTORY" "STATUS" "BRANCH" "LAST COMMIT"
    printf "%-30s %-12s %-20s %s\n" "---------" "------" "------" "-----------"

    _status_callback() {
        local target="$REPOS_DIR/$dir"
        local status branch_info last_commit

        if [[ -d "$target/.git" ]]; then
            cd "$target"
            status="${GREEN}cloned${NC}"
            branch_info="$(git branch --show-current 2>/dev/null || echo 'detached')"
            last_commit="$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-40)"
            cd "$REPOS_DIR"
        else
            status="${YELLOW}not cloned${NC}"
            branch_info="-"
            last_commit="-"
        fi

        printf "%-30s $(echo -e $status)%-1s %-20s %s\n" "$dir" "" "$branch_info" "$last_commit"
    }
    iterate_repos _status_callback
}

# List configured repos
list_repos() {
    echo
    printf "%-30s %-10s %-50s %-12s\n" "DIRECTORY" "CATEGORY" "URL" "BRANCH"
    printf "%-30s %-10s %-50s %-12s\n" "---------" "--------" "---" "------"

    while IFS='|' read -r url dir branch name cat summary; do
        [[ -z "$url" ]] && continue
        local short_url="${url#https://github.com/}"
        printf "%-30s %-10s %-50s %-12s\n" "$dir" "$cat" "$short_url" "$branch"
    done < <(parse_yaml_repos "$REPO_SOURCE")
}

# ─── Preset Validation ────────────────────────────────────────────────────────

# Validate that a directory has the required preset layout.
# Returns non-zero and prints errors if validation fails.
validate_preset() {
    local preset_dir="$1"
    local source="${2:-$preset_dir}"
    local errors=0

    if [[ ! -f "$preset_dir/preset.yaml" ]]; then
        log_error "Missing preset.yaml in: $source"
        errors=$((errors + 1))
    fi

    if [[ ! -f "$preset_dir/dev-env.yaml" ]]; then
        log_error "Missing dev-env.yaml in: $source"
        log_info "  A valid preset must contain:"
        log_info "    preset.yaml              — name, description, metadata"
        log_info "    dev-env.yaml             — list of repos to clone"
        log_info "    context/<repo>.md        — (optional) per-repo context files"
        log_info "    supplemental/<repo>.md   — (optional) fallback CLAUDE.md for repos"
        log_info "    docs/                    — (optional) architecture / debugging docs"
        log_info "    settings.local.json.tpl  — (optional) Claude Code settings template"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Read the name field from a preset directory's preset.yaml
get_preset_name_from_dir() {
    local preset_dir="$1"

    if python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import yaml
with open('$preset_dir/preset.yaml') as f:
    data = yaml.safe_load(f)
print(data.get('name', ''))
" 2>/dev/null
        return 0
    fi

    if command -v yq &>/dev/null; then
        yq -r '.name // ""' "$preset_dir/preset.yaml" 2>/dev/null
        return 0
    fi

    grep '^name:' "$preset_dir/preset.yaml" | sed 's/^name: *//;s/"//g' | head -1
}

# ─── URL Detection ────────────────────────────────────────────────────────────

# Returns 0 if the argument looks like a git URL (before any #fragment)
is_git_url() {
    local url="${1%%#*}"
    [[ "$url" == https://* || "$url" == git@* || "$url" == ssh://* || \
       "$url" == git://* || "$url" == file://* || "$url" == *.git ]]
}

# ─── External Preset Fetching ─────────────────────────────────────────────────

# Clone an external preset pack into presets/<name>/.
# Sets FETCHED_PRESET_NAME to the installed preset name.
FETCHED_PRESET_NAME=""

fetch_external_preset() {
    local raw_url="$1"
    local url="${raw_url%%#*}"
    local subdir=""
    [[ "$raw_url" == *"#"* ]] && subdir="${raw_url##*#}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Fetching preset from $url ..."
    if ! git clone --depth 1 "$url" "$tmp_dir/pack"; then
        rm -rf "$tmp_dir"
        log_error "Failed to clone $url"
        exit 1
    fi

    local pack_dir="$tmp_dir/pack"
    if [[ -n "$subdir" ]]; then
        pack_dir="$tmp_dir/pack/$subdir"
        if [[ ! -d "$pack_dir" ]]; then
            rm -rf "$tmp_dir"
            log_error "Subdirectory '$subdir' not found in $url"
            log_info "Directories available in the pack repo:"
            ls "$tmp_dir/pack/" 2>/dev/null | grep -v '^\.' | sed 's/^/  /' || true
            exit 1
        fi
    fi

    if ! validate_preset "$pack_dir" "$raw_url"; then
        rm -rf "$tmp_dir"
        exit 1
    fi

    local preset_name
    preset_name=$(get_preset_name_from_dir "$pack_dir")
    if [[ -z "$preset_name" ]]; then
        preset_name="${subdir:-$(basename "${url%.git}")}"
    fi

    local dest="$PRESETS_DIR/$preset_name"
    if [[ -d "$dest" ]]; then
        log_warn "Preset '$preset_name' already installed at presets/$preset_name/"
        read -rp "Overwrite? [y/N] " answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            rm -rf "$tmp_dir"
            log_info "Aborted."
            exit 0
        fi
        rm -rf "$dest"
    fi

    mkdir -p "$dest"
    cp -r "$pack_dir/." "$dest/"
    rm -rf "$dest/.git"

    # Record in local git exclude so the external preset is not tracked by this repo
    local exclude_file="$SCRIPT_DIR/.git/info/exclude"
    if [[ -f "$exclude_file" ]]; then
        local ignore_pattern="presets/$preset_name/"
        if ! grep -qF "$ignore_pattern" "$exclude_file" 2>/dev/null; then
            echo "$ignore_pattern" >> "$exclude_file"
        fi
    fi

    rm -rf "$tmp_dir"
    log_success "Installed preset '$preset_name' from $url"
    FETCHED_PRESET_NAME="$preset_name"
}

# ─── Preset Source Recording ─────────────────────────────────────────────────

# Inject or replace the preset: block in a dev-env.yaml file.
# Uses a regex replace so comments in the rest of the file are preserved.
record_preset_source() {
    local yaml_file="$1"
    local name="$2"
    local source="$3"   # 'bundled' or the git URL
    local ref="${4:-}"
    local subdir="${5:-}"

    if ! python3 -c "import sys" 2>/dev/null; then
        log_warn "python3 not available — preset source not recorded in dev-env.yaml"
        return 0
    fi

    python3 - "$yaml_file" "$name" "$source" "$ref" "$subdir" << 'PYEOF'
import re, sys
yaml_file, name, source, ref, subdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

with open(yaml_file) as f:
    text = f.read()

lines = ['preset:', f'  name: {name}', f'  source: {source}']
if ref:
    lines.append(f'  ref: {ref}')
if subdir:
    lines.append(f'  subdir: {subdir}')
block = '\n'.join(lines)

# Replace an existing preset key — handles both scalar (preset: tnf) and
# mapping (preset:\n  name: tnf\n  ...) forms.
new_text = re.sub(
    r'^preset:[^\n]*(?:\n[ \t]+[^\n]*)*',
    block,
    text,
    count=1,
    flags=re.MULTILINE
)

# If no preset: key existed, prepend the block
if not re.search(r'^preset:', new_text, re.MULTILINE):
    new_text = block + '\n\n' + text

with open(yaml_file, 'w') as f:
    f.write(new_text)
PYEOF
}

# ─── Init from Preset ────────────────────────────────────────────────────────

init_preset() {
    local preset_name_or_url="$1"

    if [[ -z "$preset_name_or_url" ]]; then
        log_info "Available presets:"
        echo
        for preset_dir in "$PRESETS_DIR"/*/; do
            [[ ! -d "$preset_dir" ]] && continue
            local name
            name="$(basename "$preset_dir")"
            local desc=""
            if [[ -f "$preset_dir/preset.yaml" ]]; then
                desc=$(grep '^description:' "$preset_dir/preset.yaml" | sed 's/^description: *"*//;s/"*$//')
            fi
            printf "  %-15s %s\n" "$name" "$desc"
        done
        echo
        log_info "Usage:"
        log_info "  ./setup.sh init <preset-name>         Bundled preset"
        log_info "  ./setup.sh init <url>                 External preset git URL"
        log_info "  ./setup.sh init <url#subdir>          Preset pack with multiple presets"
        exit 0
    fi

    local preset_name
    local source_type="bundled"
    local source_subdir=""

    if is_git_url "$preset_name_or_url"; then
        # External preset: fetch from git, then continue with the installed copy
        [[ "$preset_name_or_url" == *"#"* ]] && source_subdir="${preset_name_or_url##*#}"
        fetch_external_preset "$preset_name_or_url"
        preset_name="$FETCHED_PRESET_NAME"
        source_type="${preset_name_or_url%%#*}"   # store URL without fragment
    else
        preset_name="$preset_name_or_url"
    fi

    local preset_dir="$PRESETS_DIR/$preset_name"
    if [[ ! -d "$preset_dir" ]]; then
        log_error "Preset '$preset_name' not found in $PRESETS_DIR/"
        log_info "Available presets:"
        for d in "$PRESETS_DIR"/*/; do
            [[ -d "$d" ]] && echo "  $(basename "$d")"
        done
        exit 1
    fi

    if ! validate_preset "$preset_dir"; then
        exit 1
    fi

    if [[ -f "$DEV_ENV_YAML" ]]; then
        log_warn "dev-env.yaml already exists"
        read -rp "Overwrite? [y/N] " answer
        [[ "$answer" != "y" && "$answer" != "Y" ]] && { log_info "Aborted."; exit 0; }
    fi

    cp "$preset_dir/dev-env.yaml" "$DEV_ENV_YAML"
    log_success "Initialized dev-env.yaml from preset '$preset_name'"

    # Record where this preset came from so refresh-preset can re-fetch it
    record_preset_source "$DEV_ENV_YAML" "$preset_name" "$source_type" "" "$source_subdir"

    local settings_dir="$SCRIPT_DIR/.claude"
    local settings_file="$settings_dir/settings.local.json"
    if [[ ! -f "$settings_file" ]]; then
        local settings_tpl=""
        if [[ -f "$preset_dir/settings.local.json.tpl" ]]; then
            settings_tpl="$preset_dir/settings.local.json.tpl"
        elif [[ -f "$SCRIPT_DIR/settings.local.json.tpl" ]]; then
            settings_tpl="$SCRIPT_DIR/settings.local.json.tpl"
        fi
        if [[ -n "$settings_tpl" ]]; then
            mkdir -p "$settings_dir"
            cp "$settings_tpl" "$settings_file"
            log_success "Created .claude/settings.local.json from template"
        fi
    else
        log_warn ".claude/settings.local.json already exists, skipping"
    fi

    echo
    log_info "Next steps:"
    log_info "  ./setup.sh clone    — Clone all repositories"
    log_info "  ./setup.sh status   — Check repo status"
}

# ─── Refresh Preset ──────────────────────────────────────────────────────────

refresh_preset() {
    if [[ ! -f "$DEV_ENV_YAML" ]]; then
        log_error "No dev-env.yaml found. Run './setup.sh init' first."
        exit 1
    fi

    local preset_info
    preset_info=$(parse_yaml_preset "$DEV_ENV_YAML")
    local preset_name source ref subdir
    IFS='|' read -r preset_name source ref subdir <<< "$preset_info"

    if [[ -z "$preset_name" ]]; then
        log_error "No preset recorded in dev-env.yaml."
        log_info "Re-run './setup.sh init <preset>' to initialize with source tracking."
        exit 1
    fi

    log_info "Refreshing preset '$preset_name' (source: $source)"

    if [[ "$source" == "bundled" ]]; then
        local preset_dir="$PRESETS_DIR/$preset_name"
        if [[ ! -d "$preset_dir" ]]; then
            log_error "Bundled preset '$preset_name' not found at presets/$preset_name/"
            exit 1
        fi
        if ! validate_preset "$preset_dir"; then
            exit 1
        fi
    else
        # Re-fetch from git URL (source holds the URL, subdir holds the fragment path)
        local raw_url="$source"
        [[ -n "$subdir" ]] && raw_url="${source}#${subdir}"
        fetch_external_preset "$raw_url"
        preset_name="$FETCHED_PRESET_NAME"
    fi

    local preset_dir="$PRESETS_DIR/$preset_name"

    log_warn "This will overwrite dev-env.yaml with the refreshed preset."
    read -rp "Continue? [y/N] " answer
    [[ "$answer" != "y" && "$answer" != "Y" ]] && { log_info "Aborted."; exit 0; }

    cp "$preset_dir/dev-env.yaml" "$DEV_ENV_YAML"
    record_preset_source "$DEV_ENV_YAML" "$preset_name" "$source" "$ref" "$subdir"

    log_success "Preset '$preset_name' refreshed."
    log_info "Run './setup.sh clone' to clone any newly added repositories."
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo "Dev Environment Setup Script"
    echo
    echo "Usage:"
    echo "  ./setup.sh              Clone all repos (first time setup)"
    echo "  ./setup.sh clone        Clone all repos"
    echo "  ./setup.sh update       Update all repos (git pull)"
    echo "  ./setup.sh clone <dir>  Clone specific repo by directory name"
    echo "  ./setup.sh update <dir> Update specific repo by directory name"
    echo "  ./setup.sh status       Show status of all repos"
    echo "  ./setup.sh list         List configured repos"
    echo "  ./setup.sh init <name>  Initialize from a bundled preset"
    echo "  ./setup.sh init <url>   Initialize from an external preset git URL"
    echo "  ./setup.sh init <url#subdir>  External pack containing multiple presets"
    echo "  ./setup.sh refresh-preset     Re-fetch preset from its recorded source"
    echo "  ./setup.sh help         Show this help"
    echo
    echo "Configuration:"
    echo "  dev-env.yaml — repo manifest (gitignored, generated by 'init')"
    echo
    echo "Presets:"
    echo "  Run './setup.sh init' (no args) to list available bundled presets."
    echo "  External presets are fetched from git and installed into presets/<name>/."
    echo
    echo "Notes:"
    echo "  All repos are cloned with --filter=blob:none (blobless)."
    echo "  Full structure is visible, blobs fetched on-demand."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local action="${1:-clone}"
    local target="${2:-}"

    case "$action" in
        init)
            init_preset "$target"
            ;;
        refresh-preset)
            refresh_preset
            ;;
        clone)
            detect_repo_source
            if [[ -n "$target" ]]; then
                handle_specific_repo "clone" "$target"
            else
                clone_all
            fi
            ;;
        update)
            detect_repo_source
            if [[ -n "$target" ]]; then
                handle_specific_repo "update" "$target"
            else
                update_all
            fi
            ;;
        status)
            detect_repo_source
            show_status
            ;;
        list)
            detect_repo_source
            list_repos
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown action: $action"
            usage
            exit 1
            ;;
    esac
}

main "$@"
