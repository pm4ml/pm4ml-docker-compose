#!/usr/bin/env bash

set -euo pipefail

# Default configuration
KEY_SOURCE="init-vault"  # Options: init-vault, interactive
STORAGE_BACKEND="keyring"  # Options: keyring, tpm
CHECK_INTERVAL=60
MONITOR_ONLY=false
VAULT_CONTAINER="vault"
INIT_VAULT_CONTAINER="init-vault"

# Storage paths
KEYRING_NAME="vault-unseal"
TPM_PRIMARY_CTX="/tmp/vault-primary.ctx"
TPM_SEAL_PUB="/tmp/vault-seal.pub"
TPM_SEAL_PRIV="/tmp/vault-seal.priv"
TPM_SEALED_CTX="/tmp/vault-sealed.ctx"
UNSEAL_KEY_FILE="/tmp/vault-unseal.key"

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

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
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

    # Create a session keyring if it doesn't exist
    local keyring_id
    keyring_id=$(keyctl newring "$KEYRING_NAME" @u 2>/dev/null || keyctl search @u keyring "$KEYRING_NAME")

    for i in "${!keys[@]}"; do
        local key_name="unseal-key-$((i+1))"
        # Remove old key if exists
        keyctl search "$keyring_id" user "$key_name" &>/dev/null && \
            keyctl unlink "$(keyctl search "$keyring_id" user "$key_name")" "$keyring_id" 2>/dev/null || true

        # Add new key
        echo -n "${keys[$i]}" | keyctl padd user "$key_name" "$keyring_id" > /dev/null
    done

    log_success "Keys stored in keyring successfully"
}

# Retrieve keys from Linux keyring
retrieve_keys_keyring() {
    local keyring_id
    keyring_id=$(keyctl search @u keyring "$KEYRING_NAME" 2>/dev/null) || {
        log_error "Keyring '$KEYRING_NAME' not found"
        return 1
    }

    local keys=()
    for i in 1 2 3; do
        local key_name="unseal-key-$i"
        local key_id
        key_id=$(keyctl search "$keyring_id" user "$key_name" 2>/dev/null) || {
            log_error "Key '$key_name' not found in keyring"
            return 1
        }
        local key
        key=$(keyctl pipe "$key_id")
        keys+=("$key")
    done

    echo "${keys[@]}"
}

# Store keys using TPM
store_keys_tpm() {
    local keys=("$@")

    log_info "Storing keys in TPM..."

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

# Initialize and store keys
initialize_keys() {
    local keys

    if [[ "$KEY_SOURCE" == "init-vault" ]]; then
        keys=$(extract_keys_from_container) || return 1
    else
        keys=$(get_keys_interactive) || return 1
    fi

    if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
        store_keys_keyring $keys
    else
        store_keys_tpm $keys
    fi
}

# Get seal status of vault
get_seal_status() {
    docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null | \
        python3 -c "import sys, json; print('true' if json.load(sys.stdin).get('sealed', True) else 'false')" 2>/dev/null || echo "error"
}

# Unseal vault
unseal_vault() {
    local keys

    log_info "Retrieving unseal keys from $STORAGE_BACKEND..."

    if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
        keys=$(retrieve_keys_keyring) || return 1
    else
        keys=$(retrieve_keys_tpm) || return 1
    fi

    log_info "Unsealing vault..."

    local key_array=($keys)
    for key in "${key_array[@]}"; do
        docker exec "$VAULT_CONTAINER" vault operator unseal "$key" > /dev/null 2>&1 || {
            log_error "Failed to unseal vault"
            return 1
        }
    done

    log_success "Vault unsealed successfully"
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

    log_info "Vault Auto-Unseal Script Starting..."
    log_info "Configuration: key-source=$KEY_SOURCE, storage=$STORAGE_BACKEND, interval=${CHECK_INTERVAL}s, monitor-only=$MONITOR_ONLY"

    check_prerequisites

    # Initialize keys if not in monitor-only mode
    if [[ "$MONITOR_ONLY" == "false" ]]; then
        # Check if keys already exist
        local keys_exist=false
        if [[ "$STORAGE_BACKEND" == "keyring" ]]; then
            keyctl search @u keyring "$KEYRING_NAME" &>/dev/null && keys_exist=true
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
