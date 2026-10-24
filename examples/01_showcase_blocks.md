# Mermaid Lens Showcase

## 1. Named Block (`auth_sequence`)

Press `<leader>mp` inside this block to preview it, `t` to toggle Light/Dark mode, and `?` for options.

```mermaid auth_sequence
sequenceDiagram
    autonumber
    participant Client as Web Client
    participant GW as API Gateway
    participant Auth as Auth Service
    participant DB as Redis Session Store

    Client->>GW: POST /v1/login (Credentials)
    GW->>Auth: Validate(user, hash)
    Auth->>DB: SETEX session_token 3600
    DB-->>Auth: OK
    Auth-->>GW: JWT + Refresh Token
    GW-->>Client: 200 OK (Set-Cookie)
```

## 2. Entity-Relationship Diagram (Auto-Colored Entities)

Great for demonstrating deep zoom (`+`/`-`), mouse click-and-drag, and corner-to-center panning.

```mermaid ecommerce_schema
erDiagram
    direction TB
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE_ITEM : contains
    PRODUCT ||--o{ LINE_ITEM : referenced_in
    WAREHOUSE ||--o{ INVENTORY : stocks
    PRODUCT ||--o{ INVENTORY : stored_as

    CUSTOMER {
        uuid customer_id PK
        string full_name
        string email UK
        string loyalty_tier
        datetime created_at
    }
    ORDER {
        uuid order_id PK
        uuid customer_id FK
        string status
        decimal total_amount
        datetime placed_at
    }
    LINE_ITEM {
        uuid item_id PK
        uuid order_id FK
        uuid product_id FK
        int quantity
        decimal unit_price
    }
    PRODUCT {
        uuid product_id PK
        string sku UK
        string title
        decimal price
        boolean active
    }
    WAREHOUSE {
        uuid warehouse_id PK
        string region_code
        string address
    }
    INVENTORY {
        uuid warehouse_id PK,FK
        uuid product_id PK,FK
        int available_qty
        datetime updated_at
    }
```

## 3. Unnamed Blocks (Auto-Numbered in Telescope as `flowchart #1` & `flowchart #2`)

```mermaid
flowchart LR
    A[Source .md / .mmd] --> B{Cached?}
    B -->|Yes| C[Instant GPU Placement]
    B -->|No| D[Async mmdc + Progress Loader]
    D --> C
```

```mermaid
flowchart TD
     Ingress[Ingress Load Balancer] --> WorkerA[Worker Node A]
     Ingress --> WorkerB[Worker Node B]
     WorkerA --> Queue[(Kafka Topic)]
     WorkerB --> Queue
```

## 4. State Machine

```mermaid connection_lifecycle
stateDiagram-v2
    [*] --> Disconnected
    Disconnected --> Connecting : connect()
    Connecting --> Authenticated : handshake_ok
    Connecting --> Backoff : timeout / error
    Backoff --> Connecting : retry_timer
    Authenticated --> Disconnected : close()
```
