#!/bin/bash

set -euo pipefail

# Default configuration
KEY_SOURCE="init-vault"  # Options: init-vault, interactive
STORAGE_BACKEND="keyring"  # Options: keyring, tpm
CHECK_INTERVAL=60
MONITOR_ONLY=false
CLEAR_KEYS=false
VAULT_CONTAINER="vault"
INIT_VAULT_CONTAINER="init-vault"

# Storage paths
KEYRING_NAME="vault-unseal"
TPM_STORAGE_DIR="/var/lib/vault-unseal"
TPM_PRIMARY_CTX="${TPM_STORAGE_DIR}/vault-primary.ctx"
TPM_SEAL_PUB="${TPM_STORAGE_DIR}/vault-seal.pub"
TPM_SEAL_PRIV="${TPM_STORAGE_DIR}/vault-seal.priv"
TPM_SEALED_CTX="${TPM_STORAGE_DIR}/vault-sealed.ctx"
UNSEAL_KEY_FILE="/tmp/vault-unseal.key"  # This should be temporary as it contains plaintext keys

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
    cat << EOF
Vault Auto-Unseal Script

Usage: $0 [OPTIONS]

Options:
    -s, --key-source SOURCE      Source of unseal keys: 'init-vault' (default) or 'interactive'
    -b, --storage-backend TYPE   Storage backend: 'keyring' (default) or 'tpm'
    -i, --interval SECONDS       Check interval in seconds (default: 60)
    -m, --monitor-only           Only monitor seal status without unsealing
    -v, --vault-container NAME   Name of the vault container (default: vault)
    -c, --clear-keys             Clear stored keys and exit
    -h, --help                   Show this help message

Examples:
    # Use default settings (keyring storage, init-vault source, 60s interval)
    $0

    # Use TPM storage with interactive key entry
    $0 --storage-backend tpm --key-source interactive

    # Monitor only mode with 30 second interval
    $0 --monitor-only --interval 30

    # Use TPM storage from init-vault container
    $0 -b tpm -s init-vault -i 120

    # Clear stored keys from keyring
    $0 --clear-keys

    # Clear stored keys from TPM
    $0 --clear-keys --storage-backend tpm

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--key-source)
                KEY_SOURCE="$2"
                shift 2
                ;;
            -b|--storage-backend)
                STORAGE_BACKEND="$2"
                shift 2
                ;;
            -i|--interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -m|--monitor-only)
                MONITOR_ONLY=true
                shift
                ;;
            -v|--vault-container)
                VAULT_CONTAINER="$2"
                shift 2
                ;;
            -c|--clear-keys)
                CLEAR_KEYS=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}"
                usage
                ;;
        esac
    done

    # Validate arguments
    if [[ "$KEY_SOURCE" != "init-vault" && "$KEY_SOURCE" != "interactive" ]]; then
        echo -e "${RED}Error: Invalid key source. Must be 'init-vault' or 'interactive'${NC}"
        exit 1
    fi

    if [[ "$STORAGE_BACKEND" != "keyring" && "$STORAGE_BACKEND" != "tpm" ]]; then
        echo -e "${RED}Error: Invalid storage backend. Must be 'keyring' or 'tpm'${NC}"
        exit 1
    fi

    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Check interval must be a positive integer${NC}"
        exit 1
    fi
}

# Log functions - all output to stderr to avoid interfering with return values
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# Check if required tools are available
check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        log_error "docker command not found. Please install Docker."
        exit 1
    fi

    if [[ "$STORAGE_BACKEND" == "tpm" ]]; then
        if ! command -v tpm2_createprimary &> /dev/null; then
            log_error "TPM2 tools not found. Please install: sudo apt install tpm2-tools"
            exit 1
        fi
    elif [[ "$STORAGE_BACKEND" == "keyring" ]]; then
        if ! command -v keyctl &> /dev/null; then
            log_error "keyctl command not found. Please install keyutils package."
            exit 1
        fi
    fi
}

# Extract unseal keys from init-vault container logs
extract_keys_from_container() {
    log_info "Checking for $INIT_VAULT_CONTAINER container..."

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${INIT_VAULT_CONTAINER}$"; then
        log_warn "Container '$INIT_VAULT_CONTAINER' does not exist."
        log_warn "Please run the vault initialization first or use --key-source interactive"
        return 1
    fi

    log_info "Extracting unseal keys from container logs..."

    local keys=()
    for i in 1 2 3; do
        local key
        key=$(docker logs "$INIT_VAULT_CONTAINER" 2>&1 | grep "Unseal Key $i:" | awk '{print $NF}')
        if [[ -z "$key" ]]; then
            log_error "Failed to extract Unseal Key $i from container logs"
            return 1
        fi
        log_info "Extracted key $i: length=${#key} chars"
        keys+=("$key")
    done

    echo "${keys[@]}"
    return 0
}

# Prompt user to enter unseal keys interactively
get_keys_interactive() {
    log_info "Please enter the three unseal keys:"

    local keys=()
    for i in 1 2 3; do
        read -rsp "Unseal Key $i: " key
        echo
        if [[ -z "$key" ]]; then
            log_error "Key cannot be empty"
            return 1
        fi
        keys+=("$key")
    done

    echo "${keys[@]}"
    return 0
}

# Store keys using Linux keyring
store_keys_keyring() {
    local keys=("$@")

    log_info "Storing keys in Linux keyring..."

    local key_name="${KEYRING_NAME}-keys"

    # Remove old key if exists
    local old_key_id
    if old_key_id=$(keyctl search @u user "$key_name" 2>/dev/null); then
        keyctl revoke "$old_key_id" 2>/dev/null || true
        keyctl unlink "$old_key_id" @u 2>/dev/null || true
    fi

    # Add keys directly to user keyring using a special delimiter
    # Use ||| as delimiter since it won't appear in base64 keys
    local combined_keys="${keys[0]}|||${keys[1]}|||${keys[2]}"

    local new_key_id
    new_key_id=$(echo -n "$combined_keys" | keyctl padd user "$key_name" @u 2>&1) || {
        log_error "Failed to add key $key_name: $new_key_id"
        return 1
    }

    log_success "Keys stored in user keyring successfully (ID: $new_key_id)"
}

# Retrieve keys from Linux keyring
retrieve_keys_keyring() {
    local key_name="${KEYRING_NAME}-keys"
    local key_id

    # Search in user keyring
    key_id=$(keyctl search @u user "$key_name" 2>&1)
    local search_result=$?

    if [[ $search_result -ne 0 ]]; then
        log_error "Key '$key_name' not found in user keyring"
        log_error "Keyctl error: $key_id"
        return 1
    fi

    # Retrieve the combined keys
    local combined_keys
    combined_keys=$(keyctl pipe "$key_id" 2>&1) || {
        log_error "Failed to retrieve keys from keyring"
        log_error "Note: Keyring storage requires running without sudo"
        log_error "Add your user to docker group: sudo usermod -aG docker \$USER"
        return 1
    }

    # Check if we got data
    if [[ -z "$combined_keys" ]]; then
        log_error "Retrieved empty data from keyring"
        return 1
    fi

    # Split by delimiter ||| and output space-separated
    echo "$combined_keys" | sed 's/|||/ /g'
}

# Clear keys from Linux keyring
clear_keys_keyring() {
    log_info "Clearing keys from Linux keyring..."

    local cleared_count=0

    # Get all key IDs that match the vault-unseal prefix
    local key_ids
    key_ids=$(keyctl list @u 2>/dev/null | grep -oE '[0-9]+' || true)

    if [[ -z "$key_ids" ]]; then
        log_warn "No keys found in user keyring"
        return 0
    fi

    # Check each key and remove if it matches our pattern
    for key_id in $key_ids; do
        local key_desc
        key_desc=$(keyctl describe "$key_id" 2>/dev/null || true)

        # Check if this is a user key with vault-unseal prefix
        if [[ "$key_desc" =~ user.*${KEYRING_NAME} ]]; then
            local key_name
            key_name=$(echo "$key_desc" | awk -F';' '{print $NF}')

            keyctl revoke "$key_id" 2>/dev/null || true
            keyctl unlink "$key_id" @u 2>/dev/null || true
            log_info "Cleared key: $key_name (ID: $key_id)"
            ((cleared_count++))
        fi
    done

    if [[ $cleared_count -eq 0 ]]; then
        log_warn "No vault-unseal keys found to clear"
    else
        log_success "Cleared $cleared_count key(s) from keyring"
    fi
}

# Store keys using TPM
store_keys_tpm() {
    local keys=("$@")

    log_info "Storing keys in TPM..."

    # Create TPM storage directory if it doesn't exist
    if [[ ! -d "$TPM_STORAGE_DIR" ]]; then
        sudo mkdir -p "$TPM_STORAGE_DIR" || {
            log_error "Failed to create TPM storage directory: $TPM_STORAGE_DIR"
            return 1
        }
        sudo chmod 700 "$TPM_STORAGE_DIR"
        log_info "Created TPM storage directory: $TPM_STORAGE_DIR"
    fi

    # Combine the three keys into a single file (newline separated)
    printf "%s\n" "${keys[@]}" > "$UNSEAL_KEY_FILE"

    # Create primary key
    sudo tpm2_createprimary -C o -c "$TPM_PRIMARY_CTX" > /dev/null 2>&1 || {
        log_error "Failed to create TPM primary key"
        return 1
    }

    # Seal the unseal keys
    sudo tpm2_create -C "$TPM_PRIMARY_CTX" -i "$UNSEAL_KEY_FILE" -u "$TPM_SEAL_PUB" -r "$TPM_SEAL_PRIV" > /dev/null 2>&1 || {
        log_error "Failed to seal keys with TPM"
        return 1
    }

    # Load the sealed object
    sudo tpm2_load -C "$TPM_PRIMARY_CTX" -u "$TPM_SEAL_PUB" -r "$TPM_SEAL_PRIV" -c "$TPM_SEALED_CTX" > /dev/null 2>&1 || {
        log_error "Failed to load sealed keys"
        return 1
    }

    # Clean up the plaintext key file
    shred -u "$UNSEAL_KEY_FILE" 2>/dev/null || rm -f "$UNSEAL_KEY_FILE"

    log_success "Keys stored in TPM successfully"
}

# Retrieve keys from TPM
retrieve_keys_tpm() {
    if [[ ! -f "$TPM_PRIMARY_CTX" ]] || [[ ! -f "$TPM_SEAL_PUB" ]] || [[ ! -f "$TPM_SEAL_PRIV" ]]; then
        log_error "TPM key files not found. Please run key initialization first."
        return 1
    fi

    # Load the sealed context if not already loaded
    if [[ ! -f "$TPM_SEALED_CTX" ]]; then
        sudo tpm2_load -C "$TPM_PRIMARY_CTX" -u "$TPM_SEAL_PUB" -r "$TPM_SEAL_PRIV" -c "$TPM_SEALED_CTX" > /dev/null 2>&1 || {
            log_error "Failed to load sealed keys from TPM"
            return 1
        }
    fi

    # Unseal and retrieve keys
    local unsealed_data
    unsealed_data=$(sudo tpm2_unseal -c "$TPM_SEALED_CTX" 2>/dev/null) || {
        log_error "Failed to unseal keys from TPM"
        return 1
    }

    # Convert newline-separated keys to space-separated array
    echo "$unsealed_data" | tr '\n' ' ' | sed 's/ $//'
}

# Clear keys from TPM
clear_keys_tpm() {
    log_info "Clearing keys from TPM..."

    local files_removed=0
    local files=("$TPM_PRIMARY_CTX" "$TPM_SEAL_PUB" "$TPM_SEAL_PRIV" "$TPM_SEALED_CTX" "$UNSEAL_KEY_FILE")

    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            sudo shred -u "$file" 2>/dev/null || sudo rm -f "$file"
            log_info "Removed: $file"
            ((files_removed++))
        fi
    done

    # Remove the TPM storage directory if it's empty
    if [[ -d "$TPM_STORAGE_DIR" ]]; then
        if sudo rmdir "$TPM_STORAGE_DIR" 2>/dev/null; then
            log_info "Removed empty TPM storage directory: $TPM_STORAGE_DIR"
        fi
    fi

    if [[ $files_removed -eq 0 ]]; then
        log_warn "No TPM key files found to clear"
    else
        log_success "Cleared $files_removed TPM key file(s)"
    fi
}

# Initialize and store keys
initialize_keys() {
    local -a keys_array

    if [[ "$KEY_SOURCE" == "init-vault" ]]; then
        local keys_string
        keys_string=$(extract_keys_from_container) || return 1
        # Convert space-separated string to array
        read -ra keys_array <<< "$keys_string"
    else
        local keys_string
        keys_string=$(get_keys_interactive) || return 1
        # Convert space-separated string to array
        read -ra keys_array <<< "$keys_string"
    fi

    if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
        store_keys_keyring "${keys_array[@]}"
    else
        store_keys_tpm "${keys_array[@]}"
    fi
}

# Get seal status of vault
get_seal_status() {
    local status_output
    status_output=$(docker exec "$VAULT_CONTAINER" vault status 2>&1)

    if [[ $? -ne 0 ]] && [[ ! "$status_output" =~ "Sealed" ]]; then
        echo "error"
        return
    fi

    # Check if vault is sealed by looking for "Sealed" line
    if echo "$status_output" | grep -q "Sealed.*true"; then
        echo "true"
    elif echo "$status_output" | grep -q "Sealed.*false"; then
        echo "false"
    else
        echo "error"
    fi
}

# Unseal vault
unseal_vault() {
    log_info "Retrieving unseal keys from $STORAGE_BACKEND..."

    local keys_string
    if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
        keys_string=$(retrieve_keys_keyring) || {
            log_error "Failed to retrieve keys from keyring"
            return 1
        }
    else
        keys_string=$(retrieve_keys_tpm) || {
            log_error "Failed to retrieve keys from TPM"
            return 1
        }
    fi

    # Validate we got keys
    if [[ -z "$keys_string" ]]; then
        log_error "Retrieved empty keys"
        return 1
    fi

    log_info "Unsealing vault..."

    # Convert space-separated string to array
    local -a key_array
    read -ra key_array <<< "$keys_string"

    log_info "Retrieved ${#key_array[@]} keys from storage"

    # Validate we have at least 3 keys
    if [[ ${#key_array[@]} -lt 3 ]]; then
        log_error "Expected at least 3 keys, got ${#key_array[@]}"
        log_error "Keys string: '$keys_string'"
        return 1
    fi

    local unseal_count=0
    for key in "${key_array[@]}"; do
        if [[ -n "$key" ]]; then
            log_info "Applying unseal key $(($unseal_count + 1))..."
            local unseal_output
            unseal_output=$(docker exec "$VAULT_CONTAINER" vault operator unseal "$key" 2>&1)
            local unseal_result=$?

            if [[ $unseal_result -eq 0 ]]; then
                ((unseal_count++))
                log_info "Successfully applied unseal key $unseal_count"
            else
                log_error "Failed to apply unseal key $(($unseal_count + 1))"
                log_error "Vault error: $unseal_output"
                log_error "Key length: ${#key} characters"
                return 1
            fi
        else
            log_warn "Skipping empty key"
        fi
    done

    # Verify vault is actually unsealed
    local final_status
    final_status=$(get_seal_status)
    if [[ "$final_status" == "false" ]]; then
        log_success "Vault unsealed successfully (applied $unseal_count keys)"
    else
        log_error "Vault is still sealed after applying keys"
        return 1
    fi
}

# Main monitoring loop
monitor_vault() {
    log_info "Starting vault monitoring (interval: ${CHECK_INTERVAL}s, monitor-only: $MONITOR_ONLY)"

    while true; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${VAULT_CONTAINER}$"; then
            log_warn "Vault container '$VAULT_CONTAINER' is not running"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        local seal_status
        seal_status=$(get_seal_status)

        if [[ "$seal_status" == "error" ]]; then
            log_error "Failed to get vault seal status"
        elif [[ "$seal_status" == "true" ]]; then
            log_warn "Vault is SEALED"

            if [[ "$MONITOR_ONLY" == "false" ]]; then
                unseal_vault || log_error "Auto-unseal failed"
            fi
        else
            log_info "Vault is unsealed (healthy)"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# Main function
main() {
    parse_args "$@"

    # Handle clear-keys operation
    if [[ "$CLEAR_KEYS" == "true" ]]; then
        log_info "Vault Auto-Unseal Script - Clear Keys Mode"
        log_info "Storage backend: $STORAGE_BACKEND"

        if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
            clear_keys_keyring
        else
            clear_keys_tpm
        fi
        exit 0
    fi

    log_info "Vault Auto-Unseal Script Starting..."
    log_info "Configuration: key-source=$KEY_SOURCE, storage=$STORAGE_BACKEND, interval=${CHECK_INTERVAL}s, monitor-only=$MONITOR_ONLY"

    check_prerequisites

    # Initialize keys if not in monitor-only mode
    if [[ "$MONITOR_ONLY" == "false" ]]; then
        # Check if keys already exist
        local keys_exist=false
        if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
            # Check if the combined keys exist in user keyring
            keyctl search @u user "${KEYRING_NAME}-keys" &>/dev/null && keys_exist=true
        elif [[ "$STORAGE_BACKEND" == "tpm" ]]; then
            [[ -f "$TPM_SEAL_PUB" ]] && [[ -f "$TPM_SEAL_PRIV" ]] && keys_exist=true
        fi

        if [[ "$keys_exist" == "false" ]]; then
            log_info "No stored keys found. Initializing keys..."
            initialize_keys || {
                log_error "Failed to initialize keys"
                exit 1
            }
        else
            log_info "Using existing stored keys"
        fi
    fi

    # Start monitoring
    monitor_vault
}

# Run main function
main "$@"
