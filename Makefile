# SAS Viya 4 IaC on Floci AZ (local Azure emulator), hub-and-spoke.
# Every target runs against the LOCAL emulator unless TARGET=azure CONFIRM_AZURE=<spoke-sub-id> is set.
SHELL := /bin/bash
TARGET ?= local
export TARGET

.PHONY: help prerequisites floci-up floci-down reset-local hub-fixture hub-onboard spoke-plan spoke-apply \
        spoke-test upstream-demo kubernetes-baseline kubernetes-verify sas-verify sas-deploy test report \
        demo destroy trust-ca

help: ## list targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

prerequisites: ## check tools + build the Terraform provider mirror
	@for t in docker terraform kubectl jq curl python3 openssl; do command -v $$t >/dev/null || { echo "missing: $$t"; exit 1; }; done
	@docker info >/dev/null || { echo "docker daemon not running"; exit 1; }
	@scripts/provider-mirror.sh

floci-up: ## start Floci AZ (+ compat shim) with hub & spoke subscriptions
	@scripts/floci.sh up

floci-down: ## stop Floci (all emulated state is lost; run reset-local afterwards)
	@scripts/floci.sh down

reset-local: ## stop Floci, remove its sidecars and ALL local Terraform state
	@scripts/floci.sh reset

hub-fixture: floci-up ## [platform team] create the hub (VNet, DNS zones, LAW) in the HUB subscription
	@scripts/hub-fixture.sh apply

hub-onboard: ## [platform team] hub->spoke peering + DNS links for the SAS spoke
	@scripts/hub-fixture.sh onboard-spoke

spoke-plan: ## [SAS team] plan the SAS spoke (upstream viya4-iac-azure modules) in the SPOKE subscription
	@scripts/spoke.sh plan

spoke-apply: ## [SAS team] apply the SAS spoke (guarded: never re-creates AKS/PG over emulator gaps)
	@scripts/spoke.sh apply
	@[ "$(TARGET)" != local ] || scripts/cluster-bootstrap.sh
	@[ "$(TARGET)" != local ] || scripts/kubeconfig.sh

upstream-demo: floci-up ## run the UNMODIFIED sassoftware/viya4-iac-azure root module against Floci (KEEP=1 to keep it)
	@terraform/tests/upstream-conformance/run.sh

spoke-test: ## Terraform/subscription-boundary tests (PASS/FAIL/BLOCKED + evidence)
	@tests/static/run.sh
	@tests/terraform/run.sh
	@tests/report.sh > /dev/null || { echo "FAIL present: see .local/evidence/REPORT.md"; exit 1; }

kubernetes-baseline: ## RWX StorageClass + Contour ingress on the emulated AKS
	@scripts/k8s-baseline.sh

kubernetes-verify: ## API, nodes, DNS, storage, registry, PostgreSQL, ingress, NetworkPolicy
	@tests/kubernetes/run.sh

sas-verify: ## SAS readiness gate: order assets, cr.sas.com, licensed image, platform capacity
	@tests/sas/readiness.sh

sas-deploy: ## deploy real SAS Viya (requires sas-verify to have no FAIL/BLOCKED)
	@echo "sas-deploy requires an authorised SAS order in sas-viya/assets and a passing 'make sas-verify'."; exit 1

test: spoke-test kubernetes-verify sas-verify report ## run every suite and render .local/evidence/REPORT.md

report: ## render the latest results
	@tests/report.sh

demo: hub-fixture spoke-apply hub-onboard ## full demo: hub, SAS spoke (AKS, PG, ACR, network), onboarding
	@scripts/demo-summary.sh

destroy: ## destroy spoke, then hub fixture (local only)
	@[ "$(TARGET)" = local ] || { echo "make destroy is local-only; destroy Azure via your pipeline"; exit 1; }
	@AUTO_APPROVE=1 scripts/spoke.sh destroy
	@scripts/hub-fixture.sh destroy

trust-ca: ## macOS only: trust the Floci CA in the System keychain (terraform ignores SSL_CERT_FILE there)
	@[ "$$(uname -s)" = Darwin ] || { echo "only needed on macOS; Linux uses SSL_CERT_FILE automatically"; exit 0; }
	@docker compose up -d --wait floci-az >/dev/null && curl -sf http://localhost:4577/_floci/tls-cert -o .local/floci-az.crt
	@sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain .local/floci-az.crt && echo "Floci CA trusted"
