# Vault Auto-Unseal Script

A bash script that automatically monitors and unseals HashiCorp Vault when it becomes sealed. Supports both Linux Keyring and TPM 2.0 for secure key storage.

## Features

- 🔓 **Automatic Unsealing**: Continuously monitors Vault and unseals it when sealed
- 🔐 **Secure Storage**: Supports Linux Keyring and TPM 2.0 for storing unseal keys
- 📦 **Container Integration**: Extracts keys from init-vault container logs
- 🎯 **Interactive Mode**: Manual key entry option
- 👀 **Monitor-Only Mode**: Option to only monitor without auto-unsealing
- ⚙️ **Configurable**: Customizable check intervals and vault container names

## Prerequisites

### For Keyring Storage (Default)
- `keyctl` command (install: `sudo apt install keyutils`)
- Docker access for your user (Login with the same as user as running the docker compose)
- Run **without sudo only**

### For TPM Storage
- `tpm2-tools` package (install: `sudo apt install tpm2-tools`)
- TPM 2.0 hardware or simulator
- Run **with sudo**

## Installation

1. Make the script executable:
```bash
chmod +x scripts/vault-auto-unseal.sh
```

## Usage

### Basic Usage

**Keyring Storage (In memory kernal storage, requires unseal keys after a reboot):**
```bash
# Extract keys from init-vault container and start monitoring
./scripts/vault-auto-unseal.sh
```

**TPM Storage (Persistent storage ties to TPM hardware, safe across reboots):**
```bash
# Extract keys from init-vault container and store in TPM
sudo ./scripts/vault-auto-unseal.sh -b tpm
```

### Command Line Options

```
Options:
  -s, --key-source SOURCE      Source of unseal keys: 'init-vault' (default) or 'interactive'
  -b, --storage-backend TYPE   Storage backend: 'keyring' (default) or 'tpm'
  -i, --interval SECONDS       Check interval in seconds (default: 60)
  -m, --monitor-only           Only monitor seal status without unsealing
  -v, --vault-container NAME   Name of the vault container (default: vault)
  -c, --clear-keys             Clear stored keys and exit
  -h, --help                   Show help message
```

### Common Use Cases

#### 1. Extract keys from init-vault container (default)
```bash
# Using keyring
./scripts/vault-auto-unseal.sh

# Using TPM
sudo ./scripts/vault-auto-unseal.sh -b tpm
```

#### 2. Interactive key entry
```bash
# Using keyring
./scripts/vault-auto-unseal.sh -s interactive

# Using TPM
sudo ./scripts/vault-auto-unseal.sh -b tpm -s interactive
```

#### 3. Monitor-only mode (no auto-unseal)
```bash
./scripts/vault-auto-unseal.sh --monitor-only
```

#### 4. Custom check interval
```bash
# Check every 30 seconds
./scripts/vault-auto-unseal.sh -i 30

# Check every 5 minutes
./scripts/vault-auto-unseal.sh -i 300
```

#### 5. Clear stored keys

_Note: For re-initialization, init-vault container must be available or use interactive mode and input keys manually after clearing_

```bash
# Clear keyring
./scripts/vault-auto-unseal.sh --clear-keys

# Clear TPM
sudo ./scripts/vault-auto-unseal.sh -b tpm --clear-keys
```

## Storage Backends

### Linux Keyring (Default)

**Pros:**
- ✅ No sudo required
- ✅ Simple setup
- ✅ Fast access
- ✅ No special hardware needed

**Cons:**
- ❌ Keys lost on reboot
- ❌ User-specific

**Location:** User keyring (`@u`)

**How it works:**
- Keys are stored in the Linux kernel keyring
- Accessible via `keyctl` commands

### TPM 2.0

**Pros:**
- ✅ Hardware-backed security
- ✅ Persists across reboots
- ✅ Keys stored as `.pub` and `.priv` encrypted files

**Cons:**
- ❌ Requires sudo
- ❌ Needs TPM hardware
- ❌ More complex setup

**Location:** `in the project directory as .pub and .priv files`


**How it works:**
- Each of the 3 unseal keys is sealed separately with TPM
- Keys are encrypted by the TPM and can only be unsealed by the same TPM
- Provides hardware-backed security

## Key Sources

### init-vault Container (Default)

Extracts unseal keys from the `init-vault` container logs. The container exists on the first vault start and should be deleted after backup the unseal keys and root token to some other location.


### Interactive Mode

Prompts you to manually enter the three unseal keys. Useful when `init-vault` container is already removed and you already have the unseal keys backed up somewhere else


## How It Works

1. **Initialization Phase:**
   - Checks if keys are already stored
   - If not, extracts keys from init-vault container or prompts for manual entry
   - Stores keys securely in chosen backend (keyring or TPM)

2. **Monitoring Phase:**
   - Checks vault seal status at regular intervals (default: 60 seconds)
   - If sealed, retrieves keys from storage
   - Applies the 3 unseal keys to vault
   - Verifies vault is unsealed
   - Continues monitoring

## Security Considerations

### Keyring Storage
- Keys stored in kernel memory, not on disk
- Protected by Linux keyring permissions
- **Lost on reboot** - keys must be re-initialized
- Suitable for production environments but with some operational overhead (manual key re-entry after reboot)

### TPM Storage
- Keys encrypted by TPM hardware
- Stored on disk as encrypted files
- **Persists across reboots**
- Hardware-backed security
- Suitable for production environments with no operational overhead


## Troubleshooting

### Keyring: Permission Denied

**Error:** `keyctl_read_alloc: Permission denied`

**Solution:** Don't run with sudo when using keyring storage
```bash
# Wrong
sudo ./scripts/vault-auto-unseal.sh

# Correct
./scripts/vault-auto-unseal.sh
```

### Docker Permission Denied

**Error:** `permission denied while trying to connect to the Docker daemon socket`

**Solution:** Add your user to docker group
```bash
sudo usermod -aG docker $USER
newgrp docker
```

### Keys not working

**Error:** `'key' must be a valid hex or base64 string`

**Solution:** Clear and reinitialize keys
```bash
# For keyring
./scripts/vault-auto-unseal.sh --clear-keys
./scripts/vault-auto-unseal.sh

# For TPM
sudo ./scripts/vault-auto-unseal.sh -b tpm --clear-keys
sudo ./scripts/vault-auto-unseal.sh -b tpm
```

### init-vault container not found

**Error:** `Container 'init-vault' does not exist`

**Solution:**
- Use interactive mode: `./scripts/vault-auto-unseal.sh -s interactive`
- Or initialize vault first to create the init-vault container


## Running as a Service (To be tested)

Create a systemd service to run the script automatically:

### For Keyring (as user)
```bash
# Create service file
cat > ~/.config/systemd/user/vault-auto-unseal.service <<EOF
[Unit]
Description=Vault Auto-Unseal (Keyring)
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/path/to/scripts/vault-auto-unseal.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

# Enable and start
systemctl --user enable vault-auto-unseal
systemctl --user start vault-auto-unseal
systemctl --user status vault-auto-unseal
```

### For TPM (as root)
```bash
# Create service file
sudo tee /etc/systemd/system/vault-auto-unseal.service <<EOF
[Unit]
Description=Vault Auto-Unseal (TPM)
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/path/to/scripts/vault-auto-unseal.sh -b tpm
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl enable vault-auto-unseal
sudo systemctl start vault-auto-unseal
sudo systemctl status vault-auto-unseal
```

