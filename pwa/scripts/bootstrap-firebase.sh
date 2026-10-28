#!/usr/bin/env bash
# Run once from an authenticated Google Cloud Shell with project IAM administration rights.
# Creates no keys and never reads secret values. Re-running preserves existing resources.
set -euo pipefail
project_id=notedude2
site_id=notedude2-ideadude
pool_id=ideadude-github
provider_id=github
account_id=ideadude-hosting
repository_id=1240081269
repository_owner_id=20212

project_number=$(gcloud projects describe "$project_id" --format='value(projectNumber)')
account_email="$account_id@$project_id.iam.gserviceaccount.com"
pool_resource="projects/$project_number/locations/global/workloadIdentityPools/$pool_id"
provider_resource="$pool_resource/providers/$provider_id"

gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com firebasehosting.googleapis.com --project "$project_id"
if ! gcloud iam service-accounts describe "$account_email" --project "$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$account_id" --display-name='IdeaDude Hosting deploy' --project "$project_id"
fi
# Hosting writes only; the function and Cloud Run roles allow inspecting existing rewrites.
for role in roles/firebasehosting.admin roles/cloudfunctions.viewer roles/run.viewer roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:$account_email" --role="$role" --condition=None --quiet >/dev/null
done
if ! gcloud iam workload-identity-pools describe "$pool_id" --location=global --project "$project_id" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$pool_id" --location=global --display-name='IdeaDude GitHub' --project "$project_id"
fi
condition="assertion.repository_id == '$repository_id' && assertion.repository_owner_id == '$repository_owner_id' && assertion.ref == 'refs/heads/main'"
if gcloud iam workload-identity-pools providers describe "$provider_id" --workload-identity-pool="$pool_id" --location=global --project "$project_id" >/dev/null 2>&1; then
  provider_command=update-oidc
else
  provider_command=create-oidc
fi
gcloud iam workload-identity-pools providers "$provider_command" "$provider_id" \
  --project "$project_id" --location=global --workload-identity-pool="$pool_id" \
  --issuer-uri='https://token.actions.githubusercontent.com' \
  --attribute-mapping='google.subject=assertion.sub,attribute.repository_id=assertion.repository_id' \
  --attribute-condition="$condition"
gcloud iam service-accounts add-iam-policy-binding "$account_email" --project "$project_id" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/$pool_resource/attribute.repository_id/$repository_id" --quiet >/dev/null

# Use the authenticated caller to create the site and request custom-domain verification.
# Tokens stay inside the process and are never written or printed.
export IDEADUDE_PROJECT_ID="$project_id" IDEADUDE_SITE_ID="$site_id"
python3 - <<'PY'
import json, os, subprocess, urllib.request, urllib.error
project=os.environ['IDEADUDE_PROJECT_ID']; site=os.environ['IDEADUDE_SITE_ID']
token=subprocess.check_output(['gcloud','auth','print-access-token'],text=True).strip()
def api(path,method='GET',body=None):
 request=urllib.request.Request('https://firebasehosting.googleapis.com/v1beta1/'+path,method=method,
  data=json.dumps(body).encode() if body is not None else None,
  headers={'Authorization':'Bearer '+token,'Content-Type':'application/json','x-goog-user-project':project})
 try:
  with urllib.request.urlopen(request) as response:return json.load(response)
 except urllib.error.HTTPError as error:
  # Response bodies contain error descriptions, not the request's authorization header.
  payload=error.read().decode()
  if error.code==409:return {'alreadyExists':True}
  raise RuntimeError(f'Firebase API HTTP {error.code}: {payload}') from None
try:api(f'projects/{project}/sites/{site}')
except RuntimeError as error:
 if 'HTTP 404:' not in str(error):raise
 api(f'projects/{project}/sites?siteId={site}','POST',{})
print('Hosting site:',site)
custom=f'projects/{project}/sites/{site}/customDomains/ideadude.notedude.dev'
try: result=api(custom)
except RuntimeError as error:
 if 'HTTP 404:' not in str(error):raise
 result=api(f'projects/{project}/sites/{site}/customDomains?customDomainId=ideadude.notedude.dev','POST',{})
print('Custom domain registration / operation:')
print(json.dumps(result,indent=2))
print('If the response is an operation, finish domain setup in the Firebase Hosting console.')
PY
printf '\nSet these GitHub environment variables in appsciences/notedude_mobile → Settings → Environments → firebase:\n'
printf 'FIREBASE_WORKLOAD_IDENTITY_PROVIDER=%s\nFIREBASE_DEPLOY_SERVICE_ACCOUNT=%s\n' "$provider_resource" "$account_email"
printf '\nAllow deployments from main only. For automatic deployments, do not enable a per-deployment manual approval gate.\n'
