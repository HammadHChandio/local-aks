# Demo: SAS Viya 4 IaC deploying AKS into a local Azure (Floci AZ)

**What the team sees:** SAS's own `viya4-iac-azure` Terraform modules create a SAS Viya spoke (AKS,
VNet and subnets, NSG, UDR to the hub firewall, ACR with a private endpoint, PostgreSQL Flexible
Server) in a dedicated **spoke subscription**. A centrally owned **hub subscription** is consumed
read-only. Everything runs on a laptop against the Floci AZ emulator: no Azure account, no cost.

## Requirements
- Docker (Docker Desktop on macOS/Windows, or Docker Engine on Linux), about 4 GB free RAM
- `terraform` ≥ 1.10, `kubectl`, `jq`, `curl`, `python3`, `openssl`
- Linux: `.env` with `EGRESS_CA_FILE=` set only if your network re-signs TLS (corporate proxy)

## Run it (≈ 5 minutes)

```bash
make prerequisites      # tools check + Terraform provider mirror (from releases.hashicorp.com)
```

```bash
make demo               # hub (platform team) -> SAS spoke -> hub onboarding -> summary
```

What to point at during `make demo`:

| Step | Talking point |
|---|---|
| `hub-fixture` | Platform team's hub in subscription `…a001`: hub VNet, firewall/bastion subnets, private DNS zones, central Log Analytics. |
| `spoke-plan` / `spoke-apply` | SAS team's Terraform in subscription `…b001`. Uses **unmodified** upstream modules (`terraform/modules/viya4-iac-azure`, sha256-pinned). The hub is read through a separate read-only `azurerm.hub` provider. |
| plan guard | Plans fail if a subscription ID isn't a local fixture ID, if hub and spoke are the same, or if CIDRs overlap (upstream's default service CIDR `10.0.0.0/16` collides with the hub and is refused). |
| `cluster-bootstrap` / `kubeconfig` | AKS is a **real k3s cluster**; `kubectl get nodes` uses the kubeconfig from the upstream `azure_aks` module. |
| `hub-onboard` | The hub team's own step: hub→spoke peering + DNS links. The SAS state never owns hub resources. |
| summary | Resources listed **from the emulated ARM API** per subscription, plus the real containers behind them (k3s, postgres:17, registry:2). |

Then show the safety and quality checks:

```bash
make spoke-test         # PASS/FAIL/BLOCKED with evidence in .local/evidence/
```

Optional, showing SAS's upstream root module itself (unchanged) against Floci:

```bash
make upstream-demo
```

Clean up:

```bash
make destroy && make reset-local
```

## Be clear with the audience about what is and isn't real

| Real | Emulated only (API state, no behaviour) |
|---|---|
| Terraform plan/apply/destroy, state, idempotency, drift detection | VNet routing, peering, NSG and UDR enforcement, firewall |
| k3s Kubernetes API (single node) | AKS node pools (cas/compute/...) and their VM sizes |
| PostgreSQL 17 container, registry:2 container | Private endpoints, private DNS resolution, RBAC enforcement |

Known Floci 0.17.0 gaps are listed in `terraform/tests/known-emulator-drift.json`. One bug (the AKS
user-credential name) is corrected by `scripts/floci_compat_shim.py`, which rewrites that single field
and passes everything else through.

**Running SAS Viya itself** needs an x86-64 host with ≥16 vCPU / 64 GB, a SAS order (assets, licence,
certificates) and access to `cr.sas.com`. See `sas-viya/assets/README.md` and `make sas-verify`.
