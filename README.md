# workflows

Reusable GitHub Actions workflows.

## `deploy-static.yml`

Deploys a static site that the calling workflow has already built and uploaded as an artifact. It joins the tailnet as an ephemeral node tagged `tag:ci`, then runs `rsync --delete` to a deploy user whose SSH key is forced to run `rrsync`. It doesn't know how the site was built.

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # ...build the site into _site/...
      - uses: actions/upload-artifact@v7
        with:
          name: site
          path: _site/
  deploy:
    needs: build
    uses: JamieBriggsDev/workflows/.github/workflows/deploy-static.yml@v1
    with:
      artifact-name: site
      target-path: /          # relative to the rrsync folder; / is that folder
    secrets:
      DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
      DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
      TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      TS_OAUTH_SECRET: ${{ secrets.TS_OAUTH_SECRET }}
```

Each input and secret is described in the workflow's `workflow_call` block.

This repo is private, so its Actions access is set to "Accessible from repositories owned by the user".

`v1` is a moving major tag. Move it forward for backward-compatible fixes, and cut `v2` for breaking changes.
