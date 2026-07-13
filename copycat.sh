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
ESTIMATE_TOKENS=0
GITIGNORE_PATH=""
PATTERNS=()
declare -A SEEN_FILES=()
declare -A IGNORE_PATTERNS=()

# Exclusions
JUNK_DIRS_REGEX='(^|/)(\.git|\.svn|\.hg|\.idea|\.vscode|\.cache|dist|build|out|node_modules|bower_components|coverage|tmp|temp|logs|__pycache__|\.mypy_cache|CMakeFiles)(/|$)'
JUNK_EXT_REGEX='(\.(png|jpe?g|gif|webp|bmp|ico|svgz?)|(\.zip|\.tar|\.gz|\.tgz|\.bz2|\.7z|\.rar|\.xz|\.zst)|(\.pdf|\.epub|\.mobi)|(\.mp3|\.wav|\.flac|\.aac|\.ogg)|(\.mp4|\.mkv|\.webm|\.mov|\.avi)|(\.woff2?|\.ttf|\.otf)|(\.class|\.jar|\.war|\.ear)|(\.exe|\.dll|\.so|\.dylib|\.pdb))$'
MAX_FILE_SIZE=1048576 # 1 MB in bytes

# Logging Helpers (Respects VERBOSE status)
log_info()  { [[ $VERBOSE -eq 1 ]] && echo -e "\033[32m[INFO]\033[0m $*" >&2 || true; }
log_warn()  { [[ $VERBOSE -eq 1 ]] && echo -e "\033[33m[WARN]\033[0m $*" >&2 || true; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

usage() {
    cat <<'EOF'
Usage:
  copycat [-d DEPTH] [--include-junk] [-m, --markdown] [-t, --tree] [-v, --verbose] [--tokens] [--gitignore] [--gitignore-file PATH] [-h, --help] [glob...]

Options:
  -d DEPTH        Max recursion depth (like find -maxdepth). 0 = only current level.
  --include-junk  Include files normally skipped (binary/large/junk types).
  -m, --markdown  Wrap file contents in Markdown code blocks with syntax highlighting tags.
  -t, --tree      Prepend a visual file tree of matched items at the top of the output.
  -v, --verbose   Print progress logs (including files being processed) to stderr.
  --tokens        Print a rough estimate of the total LLM token count to stderr.
  --gitignore     Respect ./.gitignore to exclude paths.
  --gitignore-file PATH
                  Respect the specified .gitignore-style file to exclude paths.
  -h, --help      Show this help text.

If no glob patterns are provided, the script defaults to "*" (current directory).
EOF
}

load_gitignore() {
    local path="$1"
    if [[ -f "$path" ]]; then
        log_info "Loading gitignore rules from: $path"
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=$(echo "$line" | sed 's/[[:space:]]*$//;s/\r$//')
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            IGNORE_PATTERNS["$line"]=1
        done < "$path"
    else
        log_warn "Specified gitignore file not found: $path"
    fi
}

is_gitignored() {
    local f="$1"
    local rel_f="${f#"$PWD/"}"
    local base_name
    base_name=$(basename "$f")

    for pat in "${!IGNORE_PATTERNS[@]}"; do
        if [[ "$pat" == */ ]]; then
            local dir_pat="${pat%/}"
            if [[ "$rel_f" == "$dir_pat" || "$rel_f" == "$dir_pat"/* || "/$rel_f" == */"$dir_pat"/* ]]; then
                return 0
            fi
        elif [[ "$rel_f" == $pat || "$rel_f" == */$pat || "$base_name" == $pat ]]; then
            return 0
        fi
    done
    return 1
}

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
            --tokens)
                ESTIMATE_TOKENS=1
                shift
                ;;
            --gitignore)
                GITIGNORE_PATH="$PWD/.gitignore"
                shift
                ;;
            --gitignore=*)
                GITIGNORE_PATH="${1#--gitignore=}"
                if [[ -z "$GITIGNORE_PATH" ]]; then
                    log_error "--gitignore=PATH requires a non-empty path"
                    exit 1
                fi
                shift
                ;;
            --gitignore-file)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    log_error "--gitignore-file requires a path argument"
                    exit 1
                fi
                GITIGNORE_PATH="$2"
                shift 2
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

    if [[ -n "$GITIGNORE_PATH" ]]; then
        if is_gitignored "$f"; then
            log_info "Skipping gitignored file: $f"
            return 0
        fi
    fi

    if [[ $INCLUDE_JUNK -eq 0 && $bypass_junk_filter -eq 0 ]]; then
        if [[ "$f" =~ $JUNK_DIRS_REGEX ]]; then return 0; fi
        if [[ "$f" =~ $JUNK_EXT_REGEX ]]; then return 0; fi

        local sz
        sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
        if [[ "$sz" -gt $MAX_FILE_SIZE ]]; then return 0; fi

        if ! is_likely_text "$f"; then return 0; fi
    fi

    log_info "Processing file: $f"
    SEEN_FILES["$f"]=1
}

maybe_traverse_match() {
    local m="$1"
    [[ -e "$m" ]] || return 0

    # If it's known junk and we aren't forcing junk inclusion, skip it entirely
    if [[ $INCLUDE_JUNK -eq 0 ]]; then
        if [[ "$m" =~ $JUNK_DIRS_REGEX || "$m" =~ $JUNK_EXT_REGEX ]]; then
            log_info "Skipping junk path: $m"
            return 0
        fi
    fi

    if [[ -f "$m" ]]; then
        add_file_if_ok "$m" 0
        return 0
    fi

    if [[ -d "$m" ]]; then
        local depth_args=()
        if [[ -n "$DEPTH" ]]; then
            depth_args=(-maxdepth "$DEPTH")
        fi

        if [[ $INCLUDE_JUNK -eq 0 ]]; then
            while IFS= read -r f; do
                add_file_if_ok "$f" 0
            done < <(
                find "$m" "${depth_args[@]}" \
                    \( -mindepth 1 -type d \
                    \( -name ".git" \
                    -o -name ".svn" \
                    -o -name ".hg" \
                    -o -name ".idea" \
                    -o -name ".vscode" \
                    -o -name "dist" \
                    -o -name "build" \
                    -o -name "out" \
                    -o -name "node_modules" \
                    -o -name "coverage" \
                    -o -name "__pycache__" \
                    -o -name ".mypy_cache" \
                    -o -name "CMakeFiles" \
                    -o -name "tmp" \
                    -o -name "temp" \
                    -o -name "logs" \) -prune \) \
                    -o -type f -print 2>/dev/null
            )
        else
            while IFS= read -r f; do
                add_file_if_ok "$f" 1
            done < <(find "$m" "${depth_args[@]}" -type f 2>/dev/null)
        fi
    fi
}

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

generate_file_tree() {
    local -A nodes=()
    local path part accum

    while IFS= read -r path; do
        accum=""
        IFS='/' read -ra parts <<< "$path"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            if [[ -z "$accum" ]]; then
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

    if [[ $ESTIMATE_TOKENS -eq 1 ]]; then
        local total_chars
        total_chars=$(wc -c < "$infile")
        local estimated_tokens=$((total_chars / 4))
        echo -e "\033[34m[TOKEN ESTIMATE]\033[0m Roughly ~${estimated_tokens} tokens (${total_chars} raw bytes)" >&2
    fi

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
        [[ $VERBOSE -eq 1 ]] && log_warn "No system clipboard engine found. Printing to stdout:\n" >&2
        cat "$infile"
    fi
}

cleanup_tmp() {
    if [[ -n "${OUT_TMP:-}" && -f "$OUT_TMP" ]]; then
        rm -f "$OUT_TMP"
    fi
}

main() {
    parse_args "$@"

    if [[ -n "$GITIGNORE_PATH" ]]; then
        load_gitignore "$GITIGNORE_PATH"
    fi

    shopt -s globstar nullglob

    for pat in "${PATTERNS[@]}"; do
        local matches
        eval "matches=( $pat )" 2>/dev/null || matches=( $pat )

        if [[ ${#matches[@]} -eq 0 ]]; then
            continue
        fi

        for m in "${matches[@]}"; do
            local target="$m"
            if [[ "$m" != /* ]]; then
                target="$PWD/$m"
            fi

            if [[ -d "$target" ]]; then
                target="$(cd "$target" && pwd)"
            else
                target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
            fi
            maybe_traverse_match "$target"
        done
    done

    if [[ ${#SEEN_FILES[@]} -eq 0 ]]; then
        log_warn "No matching text files found."
        exit 0
    fi

    local files_sorted
    mapfile -t files_sorted < <(printf '%s\n' "${!SEEN_FILES[@]}" | sort)

    global_tmp="$(mktemp)"
    export OUT_TMP="$global_tmp"
    trap cleanup_tmp EXIT

    # Prepend Tree Structure
    if [[ $SHOW_TREE -eq 1 ]]; then
        if [[ $USE_MARKDOWN -eq 1 ]]; then
            printf "### Project Directory Structure\n\`\`\`text\n.\n" >> "$OUT_TMP"
            printf "%s\n" "${files_sorted[@]}" | generate_file_tree >> "$OUT_TMP"
            printf "\`\`\`\n\n" >> "$OUT_TMP"
        else
            printf "======================================================================\n" >> "$OUT_TMP"
            printf "DIRECTORY TREE\n" >> "$OUT_TMP"
            printf "======================================================================\n.\n" >> "$OUT_TMP"
            printf "%s\n" "${files_sorted[@]}" | generate_file_tree >> "$OUT_TMP"
            printf "\n\n" >> "$OUT_TMP"
        fi
    fi

# Append Files
    for abs in "${files_sorted[@]}"; do
        [[ -f "$abs" ]] || continue
        local base
        base="$(basename "$abs")"

        if [[ $USE_MARKDOWN -eq 1 ]]; then
            local lang
            lang="$(get_lang_tag "$base")"
            {
                printf '### %s\n' "$abs"
                printf '```%s\n' "$lang"
                cat -- "$abs"
                printf '\n```\n\n'
            } >> "$OUT_TMP"
        else
            {
                printf '======================================================================\n'
                printf 'FILE: %s (%s)\n' "$abs" "$base"
                printf '======================================================================\n'
                cat -- "$abs"
                printf '\n\n'
            } >> "$OUT_TMP"
        fi
    done

    copy_to_clipboard "$OUT_TMP"
}

main "$@"
