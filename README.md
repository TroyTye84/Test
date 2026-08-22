# GreenGeeks Deployment Repository

Manage a GreenGeeks (cPanel) site from Git. Push to `main`, and the site
updates itself — no FTP client, no dragging files into File Manager.

Everything in [`public_html/`](public_html/) becomes the contents of your
site's document root. Everything else in this repo is tooling and never
gets published.

---

## How it works

```
   you push            GitHub Actions           cPanel on GreenGeeks
  ──────────►  main  ──────────────────►  1. pull newest commit from GitHub
                                          2. run .cpanel.yml
                                             └─► deploy/remote-deploy.sh
                                                 ├─ create folders (dirs.txt)
                                                 ├─ sync public_html/ ─► ~/public_html
                                                 ├─ fix permissions
                                                 └─ write .deployed-version
```

GreenGeeks holds its own clone of this repo. Deploys are a two-step
instruction to cPanel — *pull*, then *deploy* — issued over the cPanel API
either by GitHub Actions or by you from the terminal.

Your GitHub credentials never touch the server, and your cPanel token never
leaves GitHub's encrypted secrets.

---

## One-time setup

### 1. Create the repository in cPanel

1. Log in to GreenGeeks → **cPanel** → **Files** → **Git™ Version Control**.
2. Click **Create**.
3. Toggle **Clone a Repository** on.
4. **Clone URL**: `https://github.com/TroyTye84/Test.git`
   *A private repo needs an SSH clone URL plus a deploy key — see
   [Private repositories](#private-repositories) below.*
5. **Repository Path**: leave the default, typically
   `/home/<cpaneluser>/repositories/Test`.
6. Click **Create**.

Copy the **Repository Path** exactly — it is `CPANEL_REPO_ROOT` everywhere below.

### 2. Create a cPanel API token

cPanel → **Security** → **Manage API Tokens** → **Create**.

Name it `github-deploy`, create it, and copy the token immediately — cPanel
shows it only once. This is *not* your cPanel password.

### 3. Point the deploy at the right folder

Open [`deploy/deploy.env`](deploy/deploy.env) and confirm `DEPLOY_PATH`.
The default publishes to your primary domain:

```bash
DEPLOY_PATH="$HOME/public_html"
```

For an addon domain or a staging subdomain, use that docroot instead:

```bash
DEPLOY_PATH="$HOME/public_html/staging"
```

### 4a. Deploy from your own machine

```bash
cp .env.example .env      # then fill in your details
./scripts/deploy.sh --check    # verifies credentials, changes nothing
./scripts/deploy.sh            # pull + deploy
```

`.env` is gitignored. It must never be committed.

### 4b. Deploy automatically from GitHub

Repo → **Settings** → **Secrets and variables** → **Actions** → **New
repository secret**, and add:

| Secret | Example | Where to find it |
|---|---|---|
| `CPANEL_HOST` | `yourdomain.com` | Your domain, or the server hostname in your GreenGeeks welcome email. No `https://`, no port. |
| `CPANEL_USER` | `greenuse` | cPanel → top-right → General Information |
| `CPANEL_TOKEN` | `ABC123…` | The token from step 2 |
| `CPANEL_REPO_ROOT` | `/home/greenuse/repositories/Test` | The Repository Path from step 1 |
| `CPANEL_PORT` | `2083` | Optional — defaults to `2083` |

Push to `main` and the deploy runs. You can also trigger one by hand from the
**Actions** tab → **Deploy to GreenGeeks** → **Run workflow**.

---

## Daily use

### Publish a change

```bash
vim public_html/index.html
git add -A && git commit -m "Update homepage" && git push
```

That is the whole workflow. Actions handles the rest.

### Create a folder on the server

Add the path to [`deploy/dirs.txt`](deploy/dirs.txt), one per line:

```
assets/uploads
logs
tmp
```

Commit and push. The folders are created on the next deploy, and are
**protected from deletion** — files your app writes into them (user uploads,
logs) survive every future deploy.

Git cannot track an empty directory, which is exactly why this file exists.

### Add files or folders with content

Just put them in `public_html/`. Directory structure is mirrored as-is.

### Useful commands

```bash
./scripts/deploy.sh              # pull latest main on cPanel, then deploy
./scripts/deploy.sh --check      # test credentials, change nothing
./scripts/deploy.sh --no-pull    # redeploy what cPanel already has
./scripts/deploy.sh --branch dev # deploy a different branch
./scripts/status.sh              # what cPanel has checked out + recent deploys
```

### Confirm what is actually live

Every deploy writes a stamp you can read from a browser:

```
https://yourdomain.com/.deployed-version
```

```
commit:   80452d6a86a5ae5ada1f08ca2d0e45e8a4baabbe
branch:   main
deployed: 2026-08-22T16:21:00Z
```

---

## Removing old files

By default a deploy **adds and overwrites, but never deletes**. A file you
delete from the repo stays on the server. That is the safe default for a
`public_html` that may also contain things this repo does not manage.

Once you are confident this repo owns everything in `DEPLOY_PATH`, set in
`deploy/deploy.env`:

```bash
DELETE_REMOVED="true"
```

Deleting a file from the repo then deletes it from the server.

**Before you flip this**, list everything it will not touch under
`PROTECTED_PATHS` in the same file. It already covers the common ones:

```
.well-known/          # SSL renewal challenges — breaking this breaks HTTPS
cgi-bin/
wp-content/uploads/   # WordPress media library
.htaccess.local
```

Folders from `dirs.txt` are protected automatically.

---

## Layout

```
.cpanel.yml              cPanel's deployment manifest — one task, calls the script below
deploy/
  deploy.env             server-side settings: where to publish, what to protect
  dirs.txt               folders to guarantee exist on the server
  remote-deploy.sh       runs ON the GreenGeeks server; does the actual work
scripts/
  deploy.sh              trigger a deploy (local or CI)
  status.sh              inspect cPanel state, read-only
  lib.sh                 shared cPanel API client
.github/workflows/
  deploy.yml             validate scripts, then deploy on push to main
public_html/             ← your site. Contents become the document root.
.env.example             template for local credentials
```

---

## Troubleshooting

**`cPanel rejected …: Access denied`**
The token is wrong, revoked, or `CPANEL_USER` is not your cPanel username.
Regenerate under Manage API Tokens.

**`could not reach <host>:2083`**
Check `CPANEL_HOST` has no `https://` and no trailing slash. Some office and
ISP networks block port 2083 — the GitHub Actions route is unaffected.

**`cPanel does not list a repository at …`**
`CPANEL_REPO_ROOT` does not match. Compare it against cPanel → Git Version
Control → **Manage**.

**Deploy reports success but the site is unchanged**
Fetch `/.deployed-version` to see which commit is live. If it is stale, cPanel
pulled nothing — confirm the branch in `DEPLOY_BRANCH` is the one you pushed.
If it is current, you are almost certainly looking at a cache; clear any
caching plugin or CDN.

**`.cpanel.yml` errors in the cPanel log**
The file must stay valid YAML with tasks indented under `deployment: tasks:`.
The GitHub Actions `validate` job checks this on every push, so a broken file
should never reach the server.

### Private repositories

cPanel cannot clone a private repo over HTTPS without credentials. Either:

- **Make the repo public**, or
- In cPanel → **SSH Access** → **Manage SSH Keys**, generate a key, copy the
  public key into GitHub → repo **Settings** → **Deploy keys** → **Add deploy
  key** (read access is enough), then clone using the SSH URL
  `git@github.com:TroyTye84/Test.git`.

---

## Notes on the existing files

`adksetup.exe` and `Hello mark` were already in this repository. They are left
untouched, and because only `public_html/` is published, neither is ever
copied to your server. `adksetup.exe` is a 1.9 MB Windows binary — Git is a
poor place for it, so consider `git rm`-ing it when convenient.
