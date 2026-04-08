# Unified Release Workflow

## Architecture

```
unified-release.yml
  ├── Job 1: Generate release notes + draft release
  └── Job 2: Create releases only in unified-version repos
                │
                ▼ (release:published events trigger Docker builds)
         ┌──────────────────────────────────────────────────┐
         │  Each repo's Docker workflow builds + pushes      │
         │  Unified-version repos build from the stamped tag │
         │  Semver repos are resolved separately by version  │
         └──────────────┬───────────────────────────────────┘
                        │
                        ▼
         unified-release.yml finalize
           ├── Resolves latest semver tags for ct-media-go, ct-traceroute-go,
           │   and ct-syslog-ingest-go unless overrides are supplied
           ├── Polls Docker Hub until the stamped and semver-managed images exist
           └── Generates appliance version files and dispatches package/OVA jobs
```

## Versioning Model

- `cisco-cdr`, `ct-quasar`, `jtapi-sidecar`, and `jtapi-operator` are stamped by `Unified Release`.
- `ct-media-go`, `ct-traceroute-go`, and `ct-syslog-ingest-go` are independently semver-released in their own repos.
- `Unified Release` never rebuilds those semver repos; it resolves their published tag and pins that tag into the appliance bundle.

## Required Step in Each Unified-Version Repo's Docker Workflow

Add this as the **last step** in each repo's Docker build workflow:

```yaml
      - name: Notify unified release
        if: always()
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.GH_RELEASE_TOKEN }}
          repository: calltelemetry/calltelemetry
          event-type: docker-build-complete
          client-payload: |
            {
              "repo": "<repo-name>",
              "version": "${{ github.event.release.tag_name || inputs.tag_name || inputs.version }}",
              "status": "${{ job.status }}",
              "image": "calltelemetry/<docker-image-name>"
            }
```

## Repos and Their Docker Workflows

| Repo | Workflow | Docker Image |
|------|----------|-------------|
| cisco-cdr | `docker-backend-release.yaml` | `calltelemetry/web` |
| ct-quasar | `publish_docker.yaml` | `calltelemetry/vue` |
| jtapi-sidecar | `docker-release.yml` | `calltelemetry/jtapi-sidecar` |
| ct-media-go | `release.yml` | `calltelemetry/ct-media-go` |
| jtapi-operator | `docker-release.yml` | `calltelemetry/jtapi-operator` |
| ct-traceroute-go | `release.yaml` | `calltelemetry/traceroute-go` |
| ct-syslog-ingest-go | `release.yml` | `calltelemetry/ct-syslog-ingest-go` |
