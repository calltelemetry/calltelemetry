# Storefront workflows

Public storefront (`calltelemetry/calltelemetry`) workflows are limited to
docs/marketing automation.

## Active

| Workflow | Purpose |
|----------|---------|
| `update-docs.yml` | Docs site updates |

## Release / OVA / appliance packaging

**Moved to private `calltelemetry/ct-release`.** Do not re-add OVA builders,
`cli.sh` / `prep.sh` mirrors, package/promote/unified-release pipelines, or
appliance firstboot scripts here.

- Bundle + GCS: `ct-release` Package Release Bundle / Unified Release
- Channel promote: `ct-release` Promote Release
- Appliance CLI/scripts source of truth: `ct-release/ova/`
