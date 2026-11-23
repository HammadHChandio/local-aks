# Vendored: sassoftware/viya4-iac-azure

* Upstream: https://github.com/sassoftware/viya4-iac-azure
* Commit:   b30d40b5fe6f73bc2fe225cd146e00ffee64c244 (2026-11-17)
* License:  Apache-2.0 (see LICENSE)
* Content:  `modules/` and `files/cloud-init/` copied **unmodified**.

`UPSTREAM.sha256` pins every file. `tests/static/test_vendored_unmodified.sh` fails if any
vendored file differs from that manifest. To upgrade, run `scripts/vendor-upstream.sh <ref>`
and review the diff — never hand-edit files in this directory.

The upstream *root* module (`main.tf`) is not vendored here because it declares its own
`provider "azurerm"` block, so it cannot receive hub/spoke provider aliases. It is still
exercised unchanged by `terraform/tests/upstream-conformance` (see docs/floci-compatibility.md).
