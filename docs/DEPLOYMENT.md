# Vibe Kanban - Fly.io Deployment Guide

This guide walks through deploying Vibe Kanban to Fly.io with PlanetScale PostgreSQL (Neki).

## Architecture Overview

The deployment consists of three Fly.io applications:

1. **vibe-kanban** - Main application (Rust/Axum backend + React frontend)
2. **vibe-kanban-electric** - ElectricSQL sync engine
3. **vibe-kanban-relay** - WebRTC/WebSocket relay (optional, for workspace features)

All three connect to a single PlanetScale PostgreSQL database configured with logical replication.

```
┌─────────────────────────────────────────┐
│              Fly.io                      │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │  vibe-kanban (port 8081)           │ │
│  │  ├─ REST API (/v1/*)               │ │
│  │  ├─ ElectricSQL proxy (/shape/*)   │ │
│  │  └─ React SPA (fallback)           │ │
│  └────────────────────────────────────┘ │
│                  ▼                       │
│  ┌────────────────────────────────────┐ │
│  │  vibe-kanban-electric (internal)   │ │
│  │  ElectricSQL sync (port 3000)      │ │
│  └────────────────────────────────────┘ │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │  vibe-kanban-relay (port 8082)     │ │
│  │  WebRTC relay (optional)           │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
                  ▼
      ┌───────────────────────┐
      │  PlanetScale Neki     │
      │  PostgreSQL           │
      │  (wal_level=logical)  │
      └───────────────────────┘
```

## Prerequisites

Before you begin, ensure you have:

- [Fly.io CLI](https://fly.io/docs/hands-on/install-flyctl/) installed and authenticated
- [PlanetScale CLI](https://planetscale.com/docs/concepts/planetscale-environment-setup) (optional, can use dashboard)
- GitHub OAuth app (or Google OAuth app)
- Access to PlanetScale Postgres (Neki)

## Step 1: PlanetScale Database Setup

### 1.1 Create PostgreSQL Cluster

Via PlanetScale dashboard:
1. Navigate to Clusters > Create Cluster
2. Select PostgreSQL (Neki)
3. Choose your region (match with Fly.io region for lower latency)
4. Select cluster tier
5. Create cluster

Via CLI:
```bash
pscale cluster create vibe-kanban --region us-west-2
```

### 1.2 Configure Logical Replication

ElectricSQL requires PostgreSQL logical replication. Configure this in your PlanetScale cluster:

1. Navigate to Clusters > Your Cluster > Parameters
2. Find `wal_level` parameter
3. Set value to `logical`
4. Save and restart cluster if prompted

Reference: [PlanetScale Logical Replication Docs](https://planetscale.com/docs/postgres/integrations/logical-cdc)

### 1.3 Get Connection String

From PlanetScale dashboard:
1. Navigate to your cluster
2. Click "Connect"
3. Copy the connection string in format:
   ```
   postgresql://username:password@host:port/database?sslmode=require
   ```

Save this for later - you'll need it for Fly secrets.

### 1.4 Database Name

PlanetScale Postgres clusters expose a single application database named
`postgres`. There is no `CREATE DATABASE` step — both the main app and
Electric connect to `postgres` directly.

## Step 2: GitHub OAuth Setup

### 2.1 Create GitHub OAuth App

1. Go to GitHub Settings > Developer settings > OAuth Apps
2. Click "New OAuth App"
3. Fill in details:
   - **Application name**: Vibe Kanban
   - **Homepage URL**: `https://vibe-kanban.fly.dev` (or your custom domain)
   - **Authorization callback URL**: `https://vibe-kanban.fly.dev/v1/oauth/github/callback`
4. Click "Register application"
5. Save the **Client ID**
6. Generate a **Client Secret** and save it

> **Note**: You'll update the URLs later if using a custom domain.

## Step 3: Generate Secrets

Generate required secrets before deployment:

```bash
# JWT secret (used for session tokens)
openssl rand -base64 48

# Electric API shared secret (set on BOTH main app and Electric app — same value)
openssl rand -base64 32

# Replication user password (set on the cdc_user you create in step 6)
openssl rand -base64 32
```

Save these values - you'll need them for Fly secrets.

## Step 4: Deploy ElectricSQL Service

Deploy the ElectricSQL sync engine first as a separate app:

```bash
cd /path/to/vibe-kanban

# Initialize Fly app (creates app, doesn't deploy yet)
fly apps create vibe-kanban-electric

# Set secrets
# Note: PlanetScale's connection-string copy button defaults to
# `sslmode=verify-full`. Electric only supports `sslmode=require` (or
# `verify-full` with a CA bundle wired up via ELECTRIC_DATABASE_CA_CERTIFICATE_FILE),
# so strip everything after `?` and replace with `?sslmode=require`.
# The user portion includes the branch ID suffix per PlanetScale's docs:
#   cdc_user.<branch-id>
fly secrets set \
  -a vibe-kanban-electric \
  DATABASE_URL="postgresql://cdc_user.<branch-id>:<replication-password>@<host>:5432/postgres?sslmode=require" \
  ELECTRIC_SECRET="<electric-shared-secret-from-step-3>"

# Deploy Electric
fly deploy \
  --config crates/remote/fly.electric.toml \
  --image electricsql/electric:1.4.13 \
  -a vibe-kanban-electric

# Create persistent volume for Electric state
fly volumes create electric_data \
  --region sjc \
  --size 1 \
  -a vibe-kanban-electric
```

> **Important**: The `DATABASE_URL` for Electric must point to the `cdc_user` role created in step 6 (which has the `REPLICATION` attribute).

## Step 5: Deploy Main Application

```bash
cd /path/to/vibe-kanban

# Initialize Fly app
fly apps create vibe-kanban

# Set required secrets
fly secrets set \
  -a vibe-kanban \
  SERVER_DATABASE_URL="postgresql://<app-user>.<branch-id>:<password>@<host>:5432/postgres?sslmode=require" \
  VIBEKANBAN_REMOTE_JWT_SECRET="<jwt-secret-from-step-3>" \
  ELECTRIC_SECRET="<electric-shared-secret-from-step-3>" \
  SERVER_PUBLIC_BASE_URL="https://vibe-kanban.fly.dev" \
  GITHUB_OAUTH_CLIENT_ID="<github-client-id>" \
  GITHUB_OAUTH_CLIENT_SECRET="<github-client-secret>"

# Optional: Email notifications via Loops
fly secrets set \
  -a vibe-kanban \
  LOOPS_EMAIL_API_KEY="<loops-api-key>"

# Optional: Azure Blob Storage for attachments
fly secrets set \
  -a vibe-kanban \
  AZURE_STORAGE_ACCOUNT_NAME="<account-name>" \
  AZURE_STORAGE_ACCOUNT_KEY="<account-key>" \
  AZURE_STORAGE_CONTAINER_NAME="issue-attachments"

# Deploy main app
fly deploy \
  --config crates/remote/fly.toml \
  --dockerfile crates/remote/Dockerfile \
  --build-arg FEATURES="" \
  -a vibe-kanban
```

The app will:
1. Build the Rust backend
2. Build the React frontend
3. Run database migrations automatically on startup

The migration that bootstraps the `electric_sync` role is best-effort — on
managed Postgres providers like PlanetScale (where the connecting role
can't `CREATE ROLE`) the migration silently skips role creation, and you
provision a replication-capable user by hand in step 6.

## Step 6: Configure Replication User on PlanetScale

PlanetScale doesn't allow the application user to grant the `REPLICATION`
role attribute, so the replication user is provisioned out of band using
the cluster's default `postgres` role.

### 6.1 Tune cluster parameters

In **Cluster > Parameters**, set:

- `wal_level` = `logical`
- `max_replication_slots` = at least `4` (`2 × replicas`)
- `max_wal_senders` = at least `4`
- `max_connections` = `100` or higher (the smallest tier ships with `25`,
  which Electric's pool exhausts on its own)

Save and apply (the cluster restarts automatically).

### 6.2 Reset the default `postgres` role to obtain admin credentials

```bash
pscale auth login   # one-time, opens a browser
pscale role reset-default <database> main --org <org> --force --format json
```

The output contains a fresh password for the `postgres` role and the
`access_host_url` to connect to.

### 6.3 Create the replication user

Connected as `postgres` via `psql`:

```sql
CREATE USER cdc_user WITH REPLICATION LOGIN PASSWORD '<replication-password-from-step-3>';
GRANT CONNECT ON DATABASE postgres TO cdc_user;
GRANT USAGE ON SCHEMA public TO cdc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO cdc_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cdc_user;
```

### 6.4 Construct the Electric `DATABASE_URL`

PlanetScale requires the branch ID as a suffix on the user portion (find
the branch ID under **Settings > Roles** or by inspecting the connection
string from any other role). The connection string must use
`sslmode=require` for Electric:

```
postgresql://cdc_user.<branch-id>:<replication-password>@<access-host>:5432/postgres?sslmode=require
```

Set it on the Electric app and restart:

```bash
fly secrets set -a vibe-kanban-electric DATABASE_URL="<the-connection-string-above>"
fly apps restart vibe-kanban-electric
```

## Step 7: Deploy Relay Server (Optional)

If you need workspace features with WebRTC tunneling, deploy the relay server:

```bash
cd /path/to/vibe-kanban

# Initialize Fly app
fly apps create vibe-kanban-relay

# Set secrets (must match main app's JWT secret)
fly secrets set \
  -a vibe-kanban-relay \
  SERVER_DATABASE_URL="postgresql://<app-user>.<branch-id>:<password>@<host>:5432/postgres?sslmode=require" \
  VIBEKANBAN_REMOTE_JWT_SECRET="<same-jwt-secret-as-main-app>"

# Deploy relay
fly deploy \
  --config crates/relay-tunnel/fly.toml \
  --dockerfile crates/relay-tunnel/Dockerfile \
  -a vibe-kanban-relay

# Update main app with relay URL
fly secrets set \
  -a vibe-kanban \
  VITE_RELAY_API_BASE_URL="https://vibe-kanban-relay.fly.dev"

# Rebuild main app with new relay URL
fly deploy \
  --config crates/remote/fly.toml \
  --dockerfile crates/remote/Dockerfile \
  --build-arg FEATURES="" \
  --build-arg VITE_RELAY_API_BASE_URL="https://vibe-kanban-relay.fly.dev" \
  -a vibe-kanban
```

## Step 8: Verify Deployment

### 8.1 Check Health Endpoints

```bash
# Main app
curl https://vibe-kanban.fly.dev/v1/health

# Relay (if deployed)
curl https://vibe-kanban-relay.fly.dev/health
```

Expected response: `200 OK`

### 8.2 View Logs

```bash
# Main app
fly logs -a vibe-kanban

# Electric
fly logs -a vibe-kanban-electric

# Relay
fly logs -a vibe-kanban-relay
```

### 8.3 Check App Status

```bash
fly status -a vibe-kanban
fly status -a vibe-kanban-electric
fly status -a vibe-kanban-relay
```

### 8.4 Test Application

1. Visit `https://vibe-kanban.fly.dev`
2. Click "Sign in with GitHub"
3. Authorize the OAuth app
4. Create an organization
5. Create a project
6. Create an issue
7. Verify real-time sync works (open in two browser windows)

## Step 9: Custom Domain (Optional)

### 9.1 Main Application Domain

```bash
# Add certificate
fly certs add vibekanban.yourdomain.com -a vibe-kanban

# Add DNS records (shown in fly certs show output)
# A record: @ -> <fly-ip-address>
# AAAA record: @ -> <fly-ipv6-address>

# Update public base URL
fly secrets set \
  -a vibe-kanban \
  SERVER_PUBLIC_BASE_URL="https://vibekanban.yourdomain.com"

# Update GitHub OAuth callback URL
# In GitHub: https://vibekanban.yourdomain.com/v1/oauth/github/callback

# Verify certificate
fly certs show vibekanban.yourdomain.com -a vibe-kanban
```

### 9.2 Relay Domain (Optional)

For workspace features, the relay needs a wildcard certificate:

```bash
# Add certificate
fly certs add relay.yourdomain.com -a vibe-kanban-relay
fly certs add "*.relay.yourdomain.com" -a vibe-kanban-relay

# Add DNS records
# A record: relay -> <fly-ip-address>
# A record: *.relay -> <fly-ip-address>
# AAAA record: relay -> <fly-ipv6-address>
# AAAA record: *.relay -> <fly-ipv6-address>

# Update main app
fly secrets set \
  -a vibe-kanban \
  VITE_RELAY_API_BASE_URL="https://relay.yourdomain.com"

# Rebuild main app
fly deploy \
  --config crates/remote/fly.toml \
  --dockerfile crates/remote/Dockerfile \
  --build-arg FEATURES="" \
  --build-arg VITE_RELAY_API_BASE_URL="https://relay.yourdomain.com" \
  -a vibe-kanban
```

## Updating the Deployment

### Update Main Application

```bash
cd /path/to/vibe-kanban
git pull origin main

# Deploy update
fly deploy \
  --config crates/remote/fly.toml \
  --dockerfile crates/remote/Dockerfile \
  --build-arg FEATURES="" \
  -a vibe-kanban
```

Migrations run automatically on startup.

### Update Relay Server

```bash
cd /path/to/vibe-kanban
git pull origin main

fly deploy \
  --config crates/relay-tunnel/fly.toml \
  --dockerfile crates/relay-tunnel/Dockerfile \
  -a vibe-kanban-relay
```

### Update ElectricSQL Version

```bash
fly deploy \
  --config crates/remote/fly.electric.toml \
  --image electricsql/electric:1.4.13 \
  -a vibe-kanban-electric
```

## Monitoring & Scaling

### View Metrics

```bash
# Open web dashboard
fly dashboard -a vibe-kanban

# SSH into machine
fly ssh console -a vibe-kanban

# Check resource usage
fly status -a vibe-kanban
```

### Scale Resources

```bash
# Scale VM size
fly scale vm shared-cpu-4x --memory 2048 -a vibe-kanban

# Scale number of machines
fly scale count 2 -a vibe-kanban

# Auto-scale configuration (edit fly.toml)
[http_service]
  min_machines_running = 1
  max_machines_running = 5
```

### Scale Electric

```bash
# Electric is typically lightweight
fly scale vm shared-cpu-2x --memory 1024 -a vibe-kanban-electric
```

## Troubleshooting

### Database Connection Issues

```bash
# Test database connection from Fly machine
fly ssh console -a vibe-kanban
# Inside machine:
wget -O- http://127.0.0.1:8081/v1/health
```

Check logs for connection errors:
```bash
fly logs -a vibe-kanban | grep -i "database\|connection"
```

### ElectricSQL Sync Not Working

1. Check Electric is running:
   ```bash
   fly status -a vibe-kanban-electric
   ```

2. Check Electric logs:
   ```bash
   fly logs -a vibe-kanban-electric
   ```

3. Verify the replication role exists and has the `REPLICATION` attribute:
   ```sql
   SELECT rolname, rolreplication, rolcanlogin
   FROM pg_roles
   WHERE rolname = 'cdc_user';

   -- And that it can read everything Electric publishes:
   SELECT grantee, privilege_type
   FROM information_schema.role_table_grants
   WHERE grantee = 'cdc_user';
   ```

4. Check internal networking:
   ```bash
   fly ssh console -a vibe-kanban
   # Inside machine:
   curl http://vibe-kanban-electric.internal:3000/v1/health
   ```

### OAuth Errors

1. Verify callback URL matches GitHub app settings
2. Check OAuth secrets are set correctly:
   ```bash
   fly ssh console -a vibe-kanban
   # Inside machine:
   env | grep GITHUB_OAUTH
   ```

3. Check logs for OAuth errors:
   ```bash
   fly logs -a vibe-kanban | grep -i oauth
   ```

### Migration Failures

If migrations fail on startup:

1. Check logs:
   ```bash
   fly logs -a vibe-kanban | grep -i migration
   ```

2. Manually run migrations (if needed):
   ```bash
   fly ssh console -a vibe-kanban
   # Migrations are embedded in the binary and run on startup
   # To force re-run, restart the app:
   fly apps restart vibe-kanban
   ```

3. Check database connection:
   ```bash
   # Verify SERVER_DATABASE_URL is correct
   fly ssh console -a vibe-kanban
   env | grep SERVER_DATABASE_URL
   ```

### Health Check Failures

If health checks fail but app is running:

1. Check health endpoint:
   ```bash
   fly ssh console -a vibe-kanban
   wget -O- http://127.0.0.1:8081/v1/health
   ```

2. Adjust grace period in fly.toml:
   ```toml
   [[services.http_checks]]
     grace_period = "15s"  # Increase if needed
   ```

3. Redeploy:
   ```bash
   fly deploy --config crates/remote/fly.toml -a vibe-kanban
   ```

## Security Checklist

- [ ] Use strong, randomly generated secrets (JWT, Electric password, `ELECTRIC_SECRET`)
- [ ] Enable HTTPS (forced by default in fly.toml)
- [ ] Ensure `ELECTRIC_INSECURE` is unset (or `false`) so Electric runs in secure mode
- [ ] Use PlanetScale SSL connections (`?sslmode=require`)
- [ ] Rotate secrets periodically
- [ ] Review IAM permissions for database roles
- [ ] Enable Fly.io private networking for Electric (internal only)
- [ ] Configure rate limiting if needed
- [ ] Set up monitoring and alerts
- [ ] Backup database regularly (PlanetScale handles this)

## Cost Optimization

### Fly.io Costs

- **Main app** (shared-cpu-2x, 1GB): ~$20-30/month
- **Electric** (shared-cpu-1x, 512MB): ~$10-15/month
- **Relay** (shared-cpu-1x, 256MB): ~$5-10/month
- **Bandwidth**: $0.02/GB after free tier (10 GB/month)
- **Storage**: $0.15/GB/month for volumes

### Optimization Tips

1. **Use auto-stop for low-traffic apps** (not recommended for production)
2. **Scale down during off-hours** (if applicable)
3. **Use smaller VMs** if traffic is low
4. **Monitor bandwidth usage** and optimize asset delivery
5. **Use CDN** for static assets if needed

### PlanetScale Costs

Check [PlanetScale pricing](https://planetscale.com/pricing) for current rates.

## Support

- [Fly.io Docs](https://fly.io/docs/)
- [Fly.io Community](https://community.fly.io/)
- [PlanetScale Docs](https://planetscale.com/docs)
- [ElectricSQL Docs](https://electric-sql.com/docs)
- [Vibe Kanban GitHub Issues](https://github.com/your-org/vibe-kanban/issues)

## Next Steps

After successful deployment:

1. Set up monitoring and alerting
2. Configure backups (PlanetScale handles automatic backups)
3. Set up CI/CD pipeline for automated deployments
4. Configure custom domain
5. Set up error tracking (Sentry integration available)
6. Enable email notifications (Loops integration)
7. Configure GitHub App for PR reviews (optional)
8. Set up analytics (PostHog integration available with billing feature)
