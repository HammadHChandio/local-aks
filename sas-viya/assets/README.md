# SAS software-order assets (not committed)

Place the files from your SAS order (my.sas.com / SAS Viya Orders CLI) here. Everything in this
directory except this README is git-ignored.

| File | Example name | Used for |
|---|---|---|
| Deployment assets | `SASViyaV4_<order>_<cadence>_<version>_deployment-assets.tgz` | `sas-bases/`, kustomize overlays, image pull secret |
| License | `SASViyaV4_<order>_license.jwt` | product licence (expiry checked by the gate) |
| Certificates | `SASViyaV4_<order>_certs.zip` | entitlement certificates for `cr.sas.com` |

Then copy `../order.env.example` to `../order.env` and fill in order number and cadence.
`make sas-verify` (readiness gate) must be all PASS before `make sas-deploy` will run.
