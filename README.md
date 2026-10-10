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

## `deploy-compose.yml`

Deploys a Docker Compose app whose images the calling workflow has already built and pushed to GHCR. It joins the tailnet as an ephemeral node tagged `tag:ci`, then SSHes in as a deploy user whose key is forced to run [`server/deploy-compose`](server/deploy-compose). On stdin it sends that script a tar holding:

- `compose.yaml`: the caller's compose file, from the commit being deployed;
- `.env`: `IMAGE_TAG`, plus every secret the job can see, single-quoted so compose reads them literally (multi-line values included);
- `ghcr-login`: the username and `GHCR_TOKEN`.

The script pulls the images using the new files, and only then replaces the live `compose.yaml` and `.env` and runs `docker compose up --detach --remove-orphans`. A failed pull leaves the running deploy as it was. A failed `up` doesn't: the new files are already in place, so fix forward or redeploy an older commit.

The compose file comes from the run's own commit, not from `image-tag`. To roll back, re-run the old commit's workflow run, so the images and compose file still match.

```yaml
jobs:
  # ...build and push ghcr.io/<owner>/<image>:${{ github.sha }}...
  deploy:
    needs: publish
    uses: JamieBriggsDev/workflows/.github/workflows/deploy-compose.yml@v1
    with:
      environment: production
      image-tag: ${{ github.sha }}
      compose-file: compose.prod.yaml   # its images use ${IMAGE_TAG}
    secrets: inherit
```

`secrets: inherit` is required: environment secrets only reach a reusable workflow when the caller passes them, and the workflow ships whatever it is given. It sends every secret to `.env` except its own: `github_token`, `IMAGE_TAG`, `GHCR_TOKEN`, `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`. Those can be repo or environment secrets. Repo and org secrets are sent too, so keep the app's secrets in the environment and nothing else at those levels. The deploy fails, naming the secret, if a value contains `'` or ends in `\` (`.env` can't carry those), or if a name starts with `COMPOSE_` (compose would read it as its own setting).

Only the compose file is sent. Anything else the stack needs must be in its images, or in the compose file itself, for example as a `configs:` entry with `content:`. Secret files can come from `.env` through `secrets: name: environment: VAR`.

### Server setup

Do this once per app:

1. Create a user for the app, for example `gmcompanion`, in the `docker` group, and give it the app dir, for example `/srv/gmcompanion`.
2. Install the script: `install -m 755 server/deploy-compose /usr/local/bin/deploy-compose`.
3. In that user's `~/.ssh/authorized_keys`, lock the deploy key to the script and the app dir:

   ```
   command="/usr/local/bin/deploy-compose /srv/gmcompanion",restrict ssh-ed25519 AAAA... deploy-compose
   ```

The `docker` group is effectively root, and whoever holds the key can run any compose file. The forced command limits the key to deploying, not to what a deploy can do. `docker login` leaves `GHCR_TOKEN` in that user's `~/.docker/config.json`, so give it only `read:packages`.

### Tests

`test/deploy-compose.test.sh` runs the workflow's `Bundle` step against fake secrets, feeds the result to the script with a fake `docker`, and checks the `.env` against the real `docker compose` when one is installed. It needs `bash`, `jq`, GNU `tar`, and `python3` with PyYAML.


## Access and versions

This repo is private, so its Actions access is set to "Accessible from repositories owned by the user".

`v1` is a moving major tag. Move it forward for backward-compatible fixes, and cut `v2` for breaking changes.
