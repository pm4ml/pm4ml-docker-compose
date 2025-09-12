# Payment Manager - Docker Compose Stack

This repository provides a **Docker Compose stack** for running the **Payment Manager** in a **lightweight, single-machine production setup**.  
It is designed for **DFSPs (Digital Financial Service Providers)** who need a simplified deployment alternative to Kubernetes-based infrastructure.

## Features
- PM4ML Core Services
- Keycloak
- API Gateway
- Vault
- Other core dependencies bundled together

## Usage

1. **DNS Configuration**

   You need to set up DNS records for your domain to point to the server where you will run this stack. The following subdomains should be configured:
   - `portal.<YOUR_DOMAIN>` - for accessing the Payment Manager Portal
   - `ml-connect.<YOUR_DOMAIN>` - for Switch to access the ML Connect service
   - `ttk.<YOUR_DOMAIN>` - for accessing the TTK

   It is recommended to use wildcard DNS records for easier management.

2. **Firewall Configuration**

   Allow incoming traffic on the following ports:
   **Required Ports:**
   - `443` (HTTPS) - for secure access to the Payment Manager Portal and the same port is used for connecting to ML Switch

   **Optional Ports:**
   - `80` (HTTP) - for certificate generation (can be disabled after setup)
   - `5050` & `6060` (TTK) - for accessing the TTK (can be restricted to user IPs)


3. **Populate .env file**

   Create a copy of the `.env.example` file and rename it to `.env`. Update the environment variables in the `.env` file as needed.

4. **SSL Certificate Setup (Required)**
    
    Before starting the services, generate SSL certificates for HAProxy

    Note: For generating certificates, ensure that port 80 is open and accessible from the internet.
    It can be disabled after certificate generation.
    
    Stop HAProxy Container if running
    ```bash
    docker compose stop haproxy
    ```
    Run Certificate Generation
    ```bash
    docker compose -f docker-compose-certbot.yaml up
    ```
    This will obtain certificates for your domain and make it available for HAProxy

5. **Start Services**
   ```bash
   git clone https://github.com/pm4ml/pm4ml-docker-compose.git
   cd pm4ml-docker-compose
   docker compose --profile portal --profile ttk up -d

## Accessing Services

- **Payment Manager Portal**: `https://portal.<YOUR_DOMAIN>`
- **TTK UI**: `https://ttk.<YOUR_DOMAIN>:6060`
