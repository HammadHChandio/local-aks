# SAS Viya 4 local lab (Floci AZ hub-and-spoke)

**Team demo:** see [docs/DEMO.md](docs/DEMO.md). In short: `make prerequisites && make demo`, then `make spoke-test`.

## Verified so far (Floci AZ 0.17.0, Terraform 1.13.4, azurerm 4.64.0)
- Floci with separate hub/spoke subscriptions and `strict-subscriptions` (unknown sub IDs → 404).
- `terraform/hub-fixture`: local stand-in for the central hub (VNet, DNS zones, LAW) in the hub subscription.
- `terraform/spoke`: SAS spoke built from **unmodified** vendored `viya4-iac-azure` modules
  (sha256-pinned), spoke as default provider, hub alias read-only. Applies cleanly from scratch;
  re-plans show 0 real changes (remaining diffs are documented Floci read-back gaps,
  `terraform/tests/known-emulator-drift.json`, never applied by `scripts/spoke.sh`).
- Static + Terraform test suites (`tests/static`, `tests/terraform`): guard rails, subscription
  placement, hub untouched, cross-sub references, drift detect/repair, CIDR-overlap refusal.

## Blockers found
- Floci gaps: no `Microsoft.Compute/disks` (upstream NFS VM), AKS agent pools are ARM-only
  (single k3s node), AKS/PG ForceNew attributes not read back, AKS user-credential name bug
  (worked around by `scripts/floci_compat_shim.py`, one rewrite only).
- This cloud sandbox cannot run pods inside k3s (`runc: can't get final child's PID`), blocks
  `cr.sas.com` / `ses.sas.download`, and has 4 vCPU / 15 GB. No SAS order assets are present.
- Running real SAS Viya therefore needs an x86-64 Linux host with SAS order assets
  (see `sas-viya/assets/README.md`, gate: `tests/sas/readiness.sh`).
