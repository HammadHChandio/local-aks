# SAS Viya 4 IaC on a local Azure (Floci AZ), hub-and-spoke

SAS's own `viya4-iac-azure` Terraform modules create a SAS Viya spoke (AKS, VNet and subnets, NSG, UDR
to the hub firewall, ACR with a private endpoint, PostgreSQL Flexible Server) in a dedicated **spoke
subscription**. A centrally owned **hub subscription** is consumed read-only. Everything runs on a
laptop against the [Floci AZ](https://github.com/floci-io/floci-az) emulator: no Azure account, no cost.

## Requirements
- Docker (Docker Desktop on macOS/Windows, or Docker Engine on Linux), about 4 GB free RAM
- `terraform` ≥ 1.10, `kubectl`, `jq`, `curl`, `python3`, `openssl`
- Works on macOS (Apple Silicon: Floci and k3s have native arm64 images) and Linux
- Only if your network re-signs TLS (corporate proxy): copy `.env.example` to `.env` and set `EGRESS_CA_FILE`

## Run the demo (≈ 5 minutes)

```bash
make prerequisites
```

macOS only, once (Terraform on macOS trusts only the Keychain, so the Floci CA must be added there):

```bash
make trust-ca
```

```bash
make demo
```

`make demo` runs, in order:

| Step | What it shows |
|---|---|
| `hub-fixture` | Platform team's hub in subscription `…a001`: hub VNet, firewall/bastion subnets, private DNS zones, central Log Analytics. |
| `spoke-apply` | SAS team's Terraform in subscription `…b001`, using **unmodified** upstream modules (`terraform/modules/viya4-iac-azure`, sha256-pinned). The hub is read through a separate read-only `azurerm.hub` provider. |
| guard rails | The plan fails if a subscription ID isn't a local fixture ID, if hub and spoke are the same, or if CIDRs overlap (upstream's default service CIDR `10.0.0.0/16` collides with the hub and is refused). |
| AKS | A **real k3s cluster**; the kubeconfig comes from the upstream `azure_aks` module (`.local/kubeconfig`). |
| `hub-onboard` | The hub team's own step: hub→spoke peering + DNS links. The SAS state never owns hub resources. |
| summary | Resources listed **from the emulated ARM API** per subscription, plus the real containers behind them (k3s, postgres:17, registry:2). |

Then run the checks (PASS/FAIL/BLOCKED with evidence in `.local/evidence/`):

```bash
make spoke-test
```

SAS's upstream **root** module itself (unmodified `viya4-iac-azure` at the vendored commit), applied
and destroyed against Floci in the spoke subscription:

```bash
make upstream-demo
```

It layers `terraform/tests/upstream-conformance/floci-profile.tfvars` on upstream defaults. That file
only sets upstream variables to switch off what Floci cannot emulate (NFS VM disks, extra node pools,
load-balancer egress IP lookup). `make upstream-conformance` runs pure upstream defaults and shows
exactly where Floci falls short.

Clean up:

```bash
make destroy
```

```bash
make reset-local
```

`make help` lists every target. **Experimental (not yet verified end to end):** `kubernetes-baseline`,
`kubernetes-verify`, `sas-verify`, `sas-deploy` (the last is a placeholder that needs a SAS order). Nothing touches real Azure unless `TARGET=azure CONFIRM_AZURE=<spoke-subscription-id>` is set.

## What is real and what is only emulated

| Real | Emulated only (API state, no behaviour) |
|---|---|
| Terraform plan/apply/destroy, state, idempotency, drift detection | VNet routing, peering, NSG and UDR enforcement, firewall |
| k3s Kubernetes API (single node) | AKS node pools (cas/compute/...) and their VM sizes |
| PostgreSQL 17 container, registry:2 container | Private endpoints, private DNS resolution, RBAC enforcement |

Floci keeps state in memory: if Floci or Docker restarts, run `make reset-local` and then `make demo` again.

## Findings
### Verified so far (Floci AZ 0.17.0, Terraform 1.13.4, azurerm 4.64.0)
- Floci with separate hub/spoke subscriptions and `strict-subscriptions` (unknown sub IDs → 404).
- `terraform/hub-fixture`: local stand-in for the central hub (VNet, DNS zones, LAW) in the hub subscription.
- `terraform/spoke`: SAS spoke built from **unmodified** vendored `viya4-iac-azure` modules
  (sha256-pinned), spoke as default provider, hub alias read-only. Applies cleanly from scratch;
  re-plans show 0 real changes (remaining diffs are documented Floci read-back gaps,
  `terraform/tests/known-emulator-drift.json`, never applied by `scripts/spoke.sh`).
- Static + Terraform test suites (`tests/static`, `tests/terraform`): guard rails, subscription
  placement, hub untouched, cross-sub references, drift detect/repair, CIDR-overlap refusal.

### Blockers found
- Floci gaps: no `Microsoft.Compute/disks` (upstream NFS VM), AKS agent pools are ARM-only
  (single k3s node), AKS/PG ForceNew attributes not read back, AKS user-credential name bug
  (worked around by `scripts/floci_compat_shim.py`, one rewrite only).
- This cloud sandbox cannot run pods inside k3s (`runc: can't get final child's PID`), blocks
  `cr.sas.com` / `ses.sas.download`, and has 4 vCPU / 15 GB. No SAS order assets are present.
- Running real SAS Viya therefore needs an x86-64 Linux host with SAS order assets
  (see `sas-viya/assets/README.md`, gate: `tests/sas/readiness.sh`).
