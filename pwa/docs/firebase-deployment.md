# IdeaDude Firebase deployment

Desired URL: **https://ideadude.notedude.dev**

Use a dedicated Firebase Hosting site, **notedude2-ideadude**, in the existing **notedude2**
project. This is a static React PWA, so classic Firebase Hosting fits; App Hosting and a new
server are unnecessary. Existing `/mcp` and `/oauth/**` rewrites call the deployed
`notedudeMcp` function in `us-central1`. Deploying this site does not redeploy the function
or replace either existing NoteDude website. Firebase manages the domain's TLS certificate.

## Automatic releases

`.github/workflows/pwa.yml` tests PRs and every push to `main`. On `main`, it deploys the
**exact production bundle tested by Playwright**, with no rebuild in the deployment job.
A merge to `main` therefore publishes after all tests pass. PRs never get deployment
credentials. Deployments serialize rather than cancelling an in-flight release. A superseded build
checks the current main SHA and skips publishing so it cannot overwrite a newer release.
You can rerun the workflow manually on `main`; manual runs on other branches only test.

The `firebase` GitHub environment uses Google Workload Identity Federation (OIDC) so
there is no service account private key or expiring Firebase login token to store.
Two nonsecret environment variables are required:

| Variable | Value |
| --- | --- |
| `FIREBASE_WORKLOAD_IDENTITY_PROVIDER` | Resource printed by the bootstrap script |
| `FIREBASE_DEPLOY_SERVICE_ACCOUNT` | `ideadude-hosting@notedude2.iam.gserviceaccount.com` |

The identity trusts only repository ID `1240081269` (`appsciences/notedude_mobile`), its
current owner ID `20212`, and `refs/heads/main`. The deployment service account can publish
Hosting and inspect existing function/Cloud Run rewrites. It cannot redeploy functions or
read their OpenAI secret. Keep the GitHub environment limited to `main`; per-release required
reviewers would pause automatic releases, so enforce code review through the main branch's
PR rules instead if desired. Do not remove existing organization approval policies.

Missing identity configuration makes the deployment job **fail visibly**, rather than
reporting a successful workflow that silently skipped deployment.

## Using an existing base64 service-account credential

If you already have an authorized service-account key, the workflow also accepts it:

1. Open https://github.com/appsciences/notedude_mobile/settings/environments.
2. Create or select the environment named `firebase`.
3. Under **Environment secrets**, click **Add environment secret**.
4. Name it `GOOGLE_APPLICATION_CREDENTIALS_B64` and paste the base64-encoded JSON key as its value.
5. Save. The key's service account needs Hosting deployment permissions and read access to
   existing function rewrites, as described above. The workflow creates the dedicated site if needed and requests its custom-domain mapping.

The workflow prefers OIDC when both identity variables are present. Otherwise it decodes
this secret into a restricted temporary file, uses Application Default Credentials and
removes the file even if deployment fails. The key is never printed or put in build artifacts.
PR jobs cannot access it. This is an alternative to the keyless setup; it does not create
Hosting sites, IAM grants or DNS records. Migrate to OIDC and remove the stored key when practical.

## One-time Google Cloud setup

An administrator of `notedude2` must run the reviewed script from an authenticated Google
Cloud Shell or workstation with gcloud, Python 3, and IAM administration permissions:

```sh
bash pwa/scripts/bootstrap-firebase.sh
```

The script enables the required identity/Hosting APIs, creates an isolated service account
and OIDC trust, creates the dedicated Hosting site, and requests the custom-domain mapping.
It prints the two nonsecret GitHub environment variable values and any domain verification
instructions. It never creates or prints service account keys. Re-running preserves existing
resources and updates this app's OIDC condition. Domain creation is asynchronous: use the
Hosting console to finish any verification step and read the final DNS records.

Set the variables in GitHub → `appsciences/notedude_mobile` → Settings → Environments →
`firebase`. Restrict deployment branches to `main`.

## Porkbun DNS and custom-domain TLS

Public DNS currently uses Porkbun nameservers. On inspection, `ideadude.notedude.dev`
resolved to the parking CNAME `pixie.porkbun.com`. That must be replaced **only for the
ideadude subdomain**, leaving the root domain and other NoteDude services untouched.

1. Open Firebase Console → project `notedude2` → Hosting → site `notedude2-ideadude` →
   Add custom domain → `ideadude.notedude.dev`. If the script already created the mapping,
   open its setup status instead.
2. In Porkbun DNS, add the ownership TXT record(s) Firebase supplies.
3. Remove the parking CNAME for host `ideadude` (or add an explicit subdomain record if the
   parking answer comes from a wildcard). Add **exactly the A/CNAME and any certificate
   validation records Firebase requests**. Do not guess a generic Firebase IP address.
4. Preserve verification records as Firebase instructs, wait for DNS propagation, and wait
   for Firebase to show the custom domain and SSL certificate as connected.
5. After deployment, run:

   ```sh
   node pwa/scripts/hosting-smoke.mjs https://notedude2-ideadude.web.app
   node pwa/scripts/hosting-smoke.mjs https://ideadude.notedude.dev
   ```

The app's sign-in page remains on the canonical `notedude2-mcp.web.app` origin. The mobile
origin is registered dynamically as the OAuth redirect URI. Because Firebase Google sign-in
runs on the canonical origin, moving the PWA alone does not require relocating the MCP
issuer or adding Firebase Auth configuration to the browser bundle.

## First release and rollback

Complete identity and site setup, then merge the PWA PR into `main` (or run the workflow on
`main` if it is already merged). Check both the `test` and `deploy` jobs and the Hosting smoke
check. The default `.web.app` URL works while custom-domain verification is pending.
Smoke checks cover assets, HTTPS headers, install manifest, service worker, and routing to
the authenticated MCP function. Real iPhone microphone, Google sign-in and a paid test-account
upload still need live QA. Server-side transcription remains subject to the existing paid
entitlement and model configuration.

Rollback a bad static release using Firebase Hosting's release history, or revert the
corresponding main-branch commit and let the same pipeline redeploy. Do not delete the site
or alter the existing backend to roll back a PWA-only change.

## Current setup status

Repository CI passed for the initial PWA. This workspace currently has no Google Cloud or
Firebase identity, and the GitHub connection cannot manage environment variables/secrets.
The MCP repository's existing deployment job was also skipping because it lacked required
configuration. No Firebase site, domain mapping, IAM grants or DNS records have yet been
created by this task. The workflow is prepared; deployment must be confirmed by a successful
Firebase deploy job before calling the app live.

The deploy job now provisions the dedicated Hosting site if absent and requests the custom
domain mapping using the supplied identity. Its service account needs Hosting admin access.
Domain DNS instructions are recorded in the workflow summary; Porkbun DNS changes remain manual.
