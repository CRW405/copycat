#!/usr/bin/env bash
set -euo pipefail

# Configuration
SCRIPT_NAME="copycat"
SOURCE_FILE="copycat.sh"

log_info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# Detect the user's active configuration file based on their shell environment
detect_shell_rc() {
    local current_shell
    current_shell=$(basename "$SHELL")

    if [[ "$current_shell" == "zsh" ]]; then
        echo "$HOME/.zshrc"
    elif [[ "$current_shell" == "bash" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "$HOME/.bash_profile"
        else
            echo "$HOME/.bashrc"
        fi
    else
        echo "$HOME/.profile"
    fi
}

install_native() {
    local bin_dir="$HOME/.local/bin"
    local dest_path="$bin_dir/$SCRIPT_NAME"

    log_info "Installing natively to $bin_dir..."
    mkdir -p "$bin_dir"

    cp "$SOURCE_FILE" "$dest_path"
    chmod +x "$dest_path"

    # Check if ~/.local/bin is in the current PATH environment variable
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        local rc_file
        rc_file=$(detect_shell_rc)
        log_info "Adding $bin_dir to PATH inside $rc_file..."
        printf '\n# Added by copycat installer\nexport PATH="%s:$PATH"\n' "$bin_dir" >> "$rc_file"
        log_info "Installation successful! Please run 'source $rc_file' or restart your terminal."
    else
        log_info "Installation successful! '$SCRIPT_NAME' is ready to use."
    fi
}

install_alias() {
    local rc_file
    rc_file=$(detect_shell_rc)
    local absolute_src
    absolute_src="$(cd "$(dirname "$SOURCE_FILE")" && pwd)/$SOURCE_FILE"

    log_info "Ensuring source file is executable..."
    chmod +x "$absolute_src"

    log_info "Injecting alias into $rc_file..."

    # Check if an alias definition already exists to avoid duplicate clutter
    if grep -q "alias $SCRIPT_NAME=" "$rc_file" 2>/dev/null; then
        log_error "An alias for '$SCRIPT_NAME' already exists in $rc_file. Aborting to avoid conflicts."
        exit 1
    fi

    printf '\n# Added by copycat installer\nalias %s="%s"\n' "$SCRIPT_NAME" "$absolute_src" >> "$rc_file"
    log_info "Alias configuration successful! Please run 'source $rc_file' to activate it."
}

main() {
    # Check if the core utility script actually exists in the working directory
    if [[ ! -f "$SOURCE_FILE" ]]; then
        log_error "Could not find '$SOURCE_FILE' in the current directory."
        log_error "Please run this installer from the folder where '$SOURCE_FILE' is saved."
        exit 1
    fi

    echo "=========================================="
    echo "      Copycat CLI Tool Installer          "
    echo "=========================================="
    echo "How would you like to install copycat?"
    echo ""
    echo "1) Native Exe (Copy to ~/.local/bin without file extension - Cleanest)"
    echo "2) Shell Alias (Inject an alias directly pointing to this absolute folder path)"
    echo "3) Cancel"
    echo "------------------------------------------"

    local choice
    read -rp "Select an option [1-3]: " choice
    echo ""

    case "$choice" in
        1)
            install_native
            ;;
        2)
            install_alias
            ;;
        3|*)
            log_info "Installation cancelled."
            exit 0
            ;;
    esac
}

main "$@"

