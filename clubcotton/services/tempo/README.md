# Tempo Service Setup

Grafana Tempo distributed tracing service for the clubcotton infrastructure.

## Configuration

The service is enabled on nas-01 with S3 storage backed by Garage.

### Service Configuration

```nix
services.clubcotton.tempo = {
  enable = true;
  s3.endpoint = "nas-01:3900";
  s3.environmentFile = config.age.secrets."tempo-s3".path;
};
```

### Default Configuration

- **Port**: 3200 (HTTP API)
- **OTLP gRPC**: 4317
- **OTLP HTTP**: 4318  
- **Storage**: S3 (Garage) + local WAL
- **Retention**: 168h (7 days)
- **Tailscale hostname**: tempo.bobtail-clownfish.ts.net
- **Data directory**: /var/lib/tempo

## Initial Setup

### 1. Create S3 Credentials Secret

```bash
# Create the secret file (run once)
agenix -e tempo-s3.age
```

Content should be:
```
TEMPO_S3_ACCESS_KEY_ID=<garage-access-key-id>
TEMPO_S3_SECRET_ACCESS_KEY=<garage-secret-access-key>
```

### 2. Setup Garage Bucket and Access Keys

After deploying the service, SSH to nas-01 and run:

```bash
# Create the S3 bucket for traces
garage bucket create tempo-traces

# Create access keys for Tempo
garage key create tempo-access-key

# Note the access key ID and secret key output, then add to secrets

# Grant bucket access to the key
garage bucket allow tempo-traces --read --write --key tempo-access-key

# Verify setup
garage bucket info tempo-traces
garage key info tempo-access-key
```

### 3. Update Secret File

Update the secret file with the actual credentials:

```bash
agenix -e tempo-s3.age
```

### 4. Restart Service

```bash
systemctl restart tempo.service
```

## Usage

### Send Traces

Tempo accepts traces via OTLP (OpenTelemetry Protocol):

- **gRPC endpoint**: `tempo.bobtail-clownfish.ts.net:4317`
- **HTTP endpoint**: `tempo.bobtail-clownfish.ts.net:4318`

### Query Traces

- **Web UI**: http://tempo.bobtail-clownfish.ts.net:3200
- **API**: http://tempo.bobtail-clownfish.ts.net:3200/api/

Common API endpoints:
- `/api/traces/<trace-id>` - Get specific trace
- `/api/search` - Search traces
- `/ready` - Health check

### Integration with Grafana

Add Tempo as a data source in Grafana:
- **URL**: http://tempo.bobtail-clownfish.ts.net:3200
- **Type**: Tempo

## Monitoring

### Service Status

```bash
systemctl status tempo.service
journalctl -u tempo.service -f
```

### Storage Usage

```bash
# Local storage
du -sh /var/lib/tempo

# S3 storage  
garage bucket info tempo-traces
```

### Metrics

Tempo exposes metrics on the HTTP port at `/metrics`.

## Troubleshooting

### Service Won't Start

1. Check S3 credentials:
   ```bash
   systemctl status tempo.service
   journalctl -u tempo.service | grep -i s3
   ```

2. Verify bucket exists and permissions:
   ```bash
   garage bucket info tempo-traces
   ```

### High Disk Usage

1. Check retention settings
2. Monitor WAL directory: `/var/lib/tempo/wal`
3. Verify S3 uploads are working

### Network Issues

1. Check firewall ports (3200, 4317, 4318)
2. Verify Tailscale connectivity
3. Test OTLP endpoints:
   ```bash
   curl -f http://localhost:3200/ready
   nc -zv localhost 4317
   nc -zv localhost 4318
   ```

## Testing

Run the service test:

```bash
nix build '.#checks.x86_64-linux.tempo'
```

For interactive debugging:

```bash
nix run '.#checks.x86_64-linux.tempo.driverInteractive'
```