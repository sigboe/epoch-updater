#!/usr/bin/env bash

# Project Epoch Updater Script
MANIFEST_URL="https://updater.project-epoch.net/api/v2/manifest"
TEMP_DIR="/tmp/epoch-updater-$"
MANIFEST_FILE="$TEMP_DIR/manifest.json"

# Check if zenity is available first (needed for error dialogs)
if ! command -v zenity >/dev/null 2>&1; then
    echo "ERROR: zenity is required but not installed." >&2
    echo "Please install zenity using your package manager:" >&2
    echo "  Ubuntu/Debian: sudo apt install zenity" >&2
    echo "  Fedora/RHEL: sudo dnf install zenity" >&2
    echo "  Arch: sudo pacman -S zenity" >&2
    exit 1
fi

# Check other required dependencies
local missing_deps=()

if ! command -v curl >/dev/null 2>&1; then
    missing_deps+=("curl")
fi

if ! command -v jq >/dev/null 2>&1; then
    missing_deps+=("jq")
fi

if ! command -v md5sum >/dev/null 2>&1; then
    missing_deps+=("md5sum (coreutils)")
fi

if ! command -v stat >/dev/null 2>&1; then
    missing_deps+=("stat (coreutils)")
fi

# If any dependencies are missing, show zenity error
if [ ${#missing_deps[@]} -gt 0 ]; then
    local deps_list=""
    for dep in "${missing_deps[@]}"; do
        deps_list="$deps_list• $dep\n"
    done

    zenity --error \
        --title="Project Epoch Updater" \
        --text="Missing required dependencies:\n\n$deps_list\nPlease install these packages using your system's package manager." \
        --width=450
    exit 1
fi


# Check if Wow.exe exists in current directory
if [ ! -f "Wow.exe" ]; then
    zenity --error \
        --title="Project Epoch Updater" \
        --text="Wow.exe not found in current directory!\n\nPlease run this updater from your World of Warcraft directory." \
        --width=400
    exit 1
fi

args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "SteamLaunch" ]; then
        # Insert $0 at position i+3 (two after SteamLaunch)
        insert_pos=$((i + 3))
        new_args=("${args[@]:0:$insert_pos}" "$0" "${args[@]:$insert_pos}")
        exec "${new_args[@]}"
        exit
    fi
done

# Create temp directory
mkdir -p "$TEMP_DIR"

# Function to convert Windows path to Unix path
win_to_unix_path() {
    echo "$1" | sed 's/\\/\//g'
}

# Function to get file size from URL (using HEAD request)
get_remote_size() {
    local url="$1"
    curl -sI "$url" | grep -i content-length | awk '{print $2}' | tr -d '\r'
}

# Main update process in subshell piped to zenity
(
    # Download manifest
    echo "# Downloading manifest..."
    if ! curl -s "$MANIFEST_URL" -o "$MANIFEST_FILE"; then
        echo "# Failed to download manifest"
        exit 1
    fi

    # Parse manifest and get file count
    total_files=$(jq -r '.Files | length' "$MANIFEST_FILE")
    if [ -z "$total_files" ] || [ "$total_files" -eq 0 ]; then
        echo "# No files found in manifest"
        exit 1
    fi

    # Arrays to store files that need downloading
    declare -a files_to_download
    declare -a file_sizes
    declare -a file_urls
    declare -a file_paths
    total_download_size=0

    # Phase 1: Check files (0-10% progress)
    echo "# Checking $total_files files..."
    files_checked=0

    while IFS= read -r file_json; do
        # Parse file info
        path=$(echo "$file_json" | jq -r '.Path')
        hash=$(echo "$file_json" | jq -r '.Hash')
        size=$(echo "$file_json" | jq -r '.Size')

        # Convert Windows path to Unix
        unix_path=$(win_to_unix_path "$path")

        # Check if file needs downloading
        needs_download=false

        if [ ! -f "$unix_path" ]; then
            needs_download=true
        else
            # Check MD5 hash
            current_hash=$(md5sum "$unix_path" 2>/dev/null | awk '{print $1}')
            if [ "$current_hash" != "$hash" ]; then
                needs_download=true
            fi
        fi

        if [ "$needs_download" = true ]; then
            # Get URL (prefer cloudflare, fallback to digitalocean, then none)
            url=$(echo "$file_json" | jq -r '.Urls.cloudflare // .Urls.digitalocean // .Urls.none')

            files_to_download+=("$unix_path")
            file_sizes+=("$size")
            file_urls+=("$url")
            file_paths+=("$path")
            total_download_size=$((total_download_size + size))
        fi

        # Update progress (0-10%)
        files_checked=$((files_checked + 1))
        progress=$((files_checked * 10 / total_files))
        echo "$progress"
        echo "# Checking files... ($files_checked/$total_files)"

    done < <(jq -c '.Files[]' "$MANIFEST_FILE")

    # If no files need downloading
    if [ ${#files_to_download[@]} -eq 0 ]; then
        echo "100"
        exit 0
    fi

    # Phase 2: Download files (10-100% progress)
    echo "# Downloading ${#files_to_download[@]} files ($(numfmt --to=iec-i --suffix=B $total_download_size))..."

    downloaded_bytes=0

    for i in "${!files_to_download[@]}"; do
        file="${files_to_download[$i]}"
        url="${file_urls[$i]}"
        size="${file_sizes[$i]}"
        path="${file_paths[$i]}"

        # Create directory if needed
        dir=$(dirname "$file")
        mkdir -p "$dir"

        echo "# Downloading: $path"

        # Start curl in background
        curl -L -s "$url" -o "$file" &
        curl_pid=$!

        # Monitor download progress
        file_downloaded_bytes=0
        while kill -0 $curl_pid 2>/dev/null; do
            if [ -f "$file" ]; then
                current_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
                file_downloaded_bytes=$current_size
            fi

            # Calculate overall progress (10-100%)
            current_total=$((downloaded_bytes + file_downloaded_bytes))
            if [ $total_download_size -gt 0 ]; then
                progress=$((10 + (current_total * 90 / total_download_size)))
                # Ensure we don't exceed 100
                [ $progress -gt 100 ] && progress=100
                echo "$progress"
            fi

            sleep 0.5
        done

        # Wait for curl to finish
        wait $curl_pid
        curl_exit_code=$?

        if [ $curl_exit_code -ne 0 ]; then
            echo "# Failed to download: $path"
            rm -f "$file"
            exit 1
        fi

        # Verify downloaded file
        downloaded_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
        if [ "$downloaded_size" -ne "$size" ]; then
            echo "# Size mismatch for: $path"
            rm -f "$file"
            exit 1
        fi

        # Update total downloaded bytes
        downloaded_bytes=$((downloaded_bytes + size))
    done

    echo "100"
    echo "# Update complete!"
    sleep 2

) 2>/dev/null | zenity --progress \
    --title="Project Epoch Updater" \
    --text="Initializing..." \
    --percentage=0 \
    --auto-close \
    --width=400

# Cleanup
rm -rf "$TEMP_DIR"

# Get exit code from the pipeline
exit_code=${PIPESTATUS[0]}

# If there are arguments (like from Steam), execute them
if [ $# -gt 0 ]; then
    exec "$@"
fi

# Otherwise, exit with the pipeline's exit code
exit $exit_code
