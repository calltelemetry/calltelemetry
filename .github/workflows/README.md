# Unified Release Workflow

## Architecture (Zero Polling)

```
unified-release.yml
  ├── Job 1: Generate release notes + draft release
  └── Job 2: Create releases in all appliance repos (matrix strategy)
                │
                ▼ (release:published events trigger Docker builds)
         ┌──────────────────────────────────────────────────┐
         │  Each repo's Docker workflow builds + pushes      │
         │  Final step: repository_dispatch back to          │
         │  calltelemetry/calltelemetry                      │
         └──────────────┬───────────────────────────────────┘
                        │
                        ▼ (repository_dispatch: docker-build-complete)
         collect-docker-builds.yml
           ├── Updates draft release checklist (✓ per repo)
           ├── Checks if all required builds complete
           └── When 6/6: triggers OVA + package-release
```

## Required Step in Each Repo's Docker Workflow

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
| ct-media | `docker-release.yml` | `calltelemetry/ct-media` |
| jtapi-operator | `docker-release.yml` | `calltelemetry/jtapi-operator` |
| ct-traceroute-go | `release.yaml` | `calltelemetry/traceroute-go` |
| ct-syslog-ingest-go | `release.yml` | `calltelemetry/ct-syslog-ingest-go` |
