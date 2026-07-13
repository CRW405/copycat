#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Copycat - Streamline code packaging for LLMs or copy-pasting
# ==============================================================================

# Global Configuration & Defaults
DEPTH=""
INCLUDE_JUNK=0
USE_MARKDOWN=0
SHOW_TREE=0
VERBOSE=0
PATTERNS=()
declare -A SEEN_FILES=()

# Exclusions
JUNK_DIRS_REGEX='(^|/)\.(git|svn|hg|idea|vscode|cache|dist|build|out|node_modules|bower_components|coverage|tmp|temp|logs|__pycache__|\.mypy_cache)(/|$)'
JUNK_EXT_REGEX='(\.(png|jpe?g|gif|webp|bmp|ico|svgz?)|(\.zip|\.tar|\.gz|\.tgz|\.bz2|\.7z|\.rar|\.xz|\.zst)|(\.pdf|\.epub|\.mobi)|(\.mp3|\.wav|\.flac|\.aac|\.ogg)|(\.mp4|\.mkv|\.webm|\.mov|\.avi)|(\.woff2?|\.ttf|\.otf)|(\.class|\.jar|\.war|\.ear)|(\.exe|\.dll|\.so|\.dylib|\.pdb))$'
MAX_FILE_SIZE=1048576 # 1 MB in bytes

# Logging Helpers (Respects VERBOSE status)
log_info()  { [[ $VERBOSE -eq 1 ]] && echo -e "\033[32m[INFO]\033[0m $*" >&2 || true; }
log_warn()  { [[ $VERBOSE -eq 1 ]] && echo -e "\033[33m[WARN]\033[0m $*" >&2 || true; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

usage() {
    cat <<'EOF'
Usage:
  copycat.sh [-d DEPTH] [--include-junk] [-m, --markdown] [-t, --tree] [-v, --verbose] [-h, --help] [glob...]

Options:
  -d DEPTH        Max recursion depth (like find -maxdepth). 0 = only current level.
  --include-junk  Include files normally skipped (binary/large/junk types).
  -m, --markdown  Wrap file contents in Markdown code blocks with syntax highlighting tags.
  -t, --tree      Prepend a visual file tree of matched items at the top of the output.
  -v, --verbose   Print progress and clipboard confirmation logs to stderr.
  -h, --help      Show this help text.

If no glob patterns are provided, the script defaults to "*" (current directory).
EOF
}

# Parse Command Line Arguments
parse_args() {
    while (($#)); do
        case "$1" in
            -d)
                DEPTH="${2:-}"
                if [[ -z "$DEPTH" || ! "$DEPTH" =~ ^[0-9]+$ ]]; then
                    log_error "-d DEPTH must be a non-negative integer"
                    exit 1
                fi
                shift 2
                ;;
            --include-junk)
                INCLUDE_JUNK=1
                shift
                ;;
            -m|--markdown)
                USE_MARKDOWN=1
                shift
                ;;
            -t|--tree)
                SHOW_TREE=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                PATTERNS+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#PATTERNS[@]} -eq 0 ]]; then
        PATTERNS=("*")
    fi
}

# Core Text Validation
is_likely_text() {
    local f="$1"
    if command -v grep >/dev/null 2>&1; then
        head -c 32768 -- "$f" 2>/dev/null | grep -I -q . && return 0 || return 1
    fi
    local sz
    sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
    [[ "$sz" -lt $MAX_FILE_SIZE ]]
}

add_file_if_ok() {
    local f="$1"
    local bypass_junk_filter="${2:-0}"
    [[ -f "$f" ]] || return 0

    # Only apply block filters if we aren't explicitly bypassing them for this target branch
    if [[ $INCLUDE_JUNK -eq 0 && $bypass_junk_filter -eq 0 ]]; then
        if [[ "$f" =~ $JUNK_DIRS_REGEX ]]; then return 0; fi
        if [[ "$f" =~ $JUNK_EXT_REGEX ]]; then return 0; fi

        local sz
        sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
        if [[ "$sz" -gt $MAX_FILE_SIZE ]]; then return 0; fi

        if ! is_likely_text "$f"; then return 0; fi
    fi

    SEEN_FILES["$f"]=1
}

maybe_traverse_match() {
    local m="$1"
    [[ -e "$m" ]] || return 0

    # Determine if this item was explicitly asked for despite matching junk patterns
    local bypass_junk_filter=0
    if [[ "$m" =~ $JUNK_DIRS_REGEX || "$m" =~ $JUNK_EXT_REGEX ]]; then
        bypass_junk_filter=1
    fi

    if [[ -f "$m" ]]; then
        add_file_if_ok "$m" "$bypass_junk_filter"
        return 0
    fi

    if [[ -d "$m" ]]; then
        local find_args=()
        if [[ -n "$DEPTH" ]]; then
            find_args=(-maxdepth "$DEPTH")
        fi

        # Only prune junk folders down-tree if we aren't explicitly targeting one right now
        if [[ $INCLUDE_JUNK -eq 0 && $bypass_junk_filter -eq 0 ]]; then
            find_args+=(
                \( -type d -name ".git" -o -name ".svn" -o -name ".hg" -o -name ".idea" -o -name ".vscode" \
                   -o -name "dist" -o -name "build" -o -name "out" -o -name "node_modules" -o -name "coverage" \
                   -o -name "__pycache__" -o -name ".mypy_cache" -o -name "tmp" -o -name "temp" -o -name "logs" \) -prune -false
            )
        fi

        while IFS= read -r f; do
            add_file_if_ok "$f" "$bypass_junk_filter"
        done < <(find "$m" "${find_args[@]}" -type f 2>/dev/null)
    fi
}

# Maps file extensions to markdown syntax mapping tags
get_lang_tag() {
    local ext="${1##*.}"
    if [[ "$1" != *.* ]]; then
        echo ""
        return
    fi
    
    case "${ext,,}" in
        py) echo "python" ;;
        js) echo "javascript" ;;
        ts) echo "typescript" ;;
        sh|bash|zsh) echo "bash" ;;
        json) echo "json" ;;
        md) echo "markdown" ;;
        html|htm) echo "html" ;;
        css) echo "css" ;;
        yml|yaml) echo "yaml" ;;
        rs) echo "rust" ;;
        go) echo "go" ;;
        rb) echo "ruby" ;;
        c|h) echo "c" ;;
        cpp|cc|hpp) echo "cpp" ;;
        cs) echo "csharp" ;;
        java) echo "java" ;;
        sql) echo "sql" ;;
        *) echo "" ;;
    esac
}

# Builds a visual text tree natively without relying on the 'tree' binary
generate_file_tree() {
    local -A nodes=()
    local path part accum
    
    while IFS= read -r path; do
        accum="."
        IFS='/' read -ra parts <<< "$path"
        for part in "${parts[@]}"; do
            if [[ "$accum" == "." ]]; then
                accum="$part"
            else
                accum="$accum/$part"
            fi
            nodes["$accum"]=1
        done
    done
    
    printf "%s\n" "${!nodes[@]}" | sort | awk -F/ '
    {
        depth = NF - 1
        indent = ""
        for (i = 0; i < depth; i++) {
            indent = indent "│   "
        }
        print indent "├── " $NF
    }' | sed 's/├── \([^/]*\)$/└── \1/'
}

copy_to_clipboard() {
    local infile="$1"
    if command -v wl-copy >/dev/null 2>&1; then
        wl-copy < "$infile"
        log_info "Copied to clipboard via wl-copy."
    elif command -v pbcopy >/dev/null 2>&1; then
        pbcopy < "$infile"
        log_info "Copied to clipboard via pbcopy."
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard < "$infile"
        log_info "Copied to clipboard via xclip."
    else
        [[ $VERBOSE -eq 1 ]] && log_warn "No system clipboard engine found (wl-copy, pbcopy, xclip). Printing to stdout instead:\n" >&2
        cat "$infile"
    fi
}

main() {
    parse_args "$@"

    shopt -s globstar nullglob

    for pat in "${PATTERNS[@]}"; do
        local matches
        eval "matches=( $pat )" 2>/dev/null || matches=( $pat )
        
        if [[ ${#matches[@]} -eq 0 ]]; then
            continue
        fi
        
        for m in "${matches[@]}"; do
            if [[ "$m" = /* ]]; then
                maybe_traverse_match "$m"
            else
                maybe_traverse_match "$PWD/$m"
            fi
        done
    done

    local files_sorted
    mapfile -t files_sorted < <(
        printf '%s\n' "${!SEEN_FILES[@]}" \
            | sed "s|^$PWD/||" \
            | sort
    )

    if [[ ${#files_sorted[@]} -eq 0 ]]; then
        log_warn "No matching text files found."
        exit 0
    fi

    local out_tmp
    out_tmp="$(mktemp)"
    trap 'rm -f "$out_tmp"' EXIT

    # Prepend Tree Structure if requested
    if [[ $SHOW_TREE -eq 1 ]]; then
        if [[ $USE_MARKDOWN -eq 1 ]]; then
            printf "### Project Directory Structure\n\`\`\`text\n.\n" >> "$out_tmp"
            printf "%s\n" "${files_sorted[@]}" | generate_file_tree >> "$out_tmp"
            printf "\`\`\`\n\n" >> "$out_tmp"
        else
            printf "======================================================================\n" >> "$out_tmp"
            printf "DIRECTORY TREE\n" >> "$out_tmp"
            printf "======================================================================\n.\n" >> "$out_tmp"
            printf "%s\n" "${files_sorted[@]}" | generate_file_tree >> "$out_tmp"
            printf "\n\n" >> "$out_tmp"
        fi
    fi

    # Append Files
    for rel in "${files_sorted[@]}"; do
        local abs="$PWD/$rel"
        local base
        base="$(basename "$rel")"
        
        if [[ $USE_MARKDOWN -eq 1 ]]; then
            local lang
            lang="$(get_lang_tag "$base")"
            {
                printf '### %s\n' "$rel"
                printf '\`\`\`%s\n' "$lang"
                cat -- "$abs"
                printf '\n\`\`\`\n\n'
            } >> "$out_tmp"
        else
            {
                printf '======================================================================\n'
                printf 'FILE: %s (%s)\n' "$rel" "$base"
                printf '======================================================================\n'
                cat -- "$abs"
                printf '\n\n'
            } >> "$out_tmp"
        fi
    done

    copy_to_clipboard "$out_tmp"
}

main "$@"
