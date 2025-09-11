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


1. **Populate .env file**

   Create a copy of the `.env.example` file and rename it to `.env`. Update the environment variables in the `.env` file as needed.

2. **SSL Certificate Setup (Required)**
    
    Before starting the services, generate SSL certificates for HAProxy
    
    Stop HAProxy Container if running
    ```bash
    docker compose stop haproxy
    ```
    Run Certificate Generation
    ```bash
    docker compose -f docker-compose-certbot.yaml up
    ```
    This will obtain certificates for your domain and make it available for HAProxy

2. **Start Services**
   ```bash
   git clone https://github.com/pm4ml/pm4ml-docker-compose.git
   cd pm4ml-docker-compose
   docker compose --profile portal --profile ttk up -d

