# Tasks

## Architecture Decisions

**Module Strategy:** Replace existing Prometheus-based `monitoring.nix` module entirely with new VictoriaMetrics stack. Create separate modules for each component (modular architecture) in `monitoring-stack/` directory.

**Domain Configuration:** All monitoring endpoints will be under `apps.ondy.org` domain (using route53 on wolf).

**Authentication:** Use per-host bearer tokens for better security and auditing. Token names: `monitoring_token_wolf`, `monitoring_token_tiger`, `monitoring_token_dino`. Nginx-based authentication using map directive for token validation.

**Module Structure:**

- `monitoring-stack/default.nix` - Main module that imports all submodules
- `monitoring-stack/victoriametrics.nix` - Metrics storage
- `monitoring-stack/loki.nix` - Log aggregation
- `monitoring-stack/grafana.nix` - Visualization and dashboards
- `monitoring-stack/alertmanager.nix` - Alert management
- `monitoring-stack/vmagent.nix` - Metrics collection agent
- `monitoring-stack/promtail.nix` - Log shipping agent

**Deployment Order:** Deploy to wolf first (all services), then tiger and dino (agents only).

---

## Test metric ingestion from all hosts

Verify VictoriaMetrics is receiving metrics from all three hosts and data is visible in Grafana.

## Test log aggregation from all hosts

Confirm Loki is receiving logs from all hosts and they're queryable in Grafana.

## Verify email alerting functionality

Trigger test alert to confirm email notifications are working through configured SMTP server.

## Document monitoring access and usage

Create documentation explaining how to access Grafana, view metrics/logs, and manage alerts for future reference.
