import {GoogleAuth} from 'google-auth-library';
import {appendFile} from 'node:fs/promises';
const project='notedude2', site='notedude2-ideadude', domain='ideadude.notedude.dev';
const auth=new GoogleAuth({scopes:['https://www.googleapis.com/auth/cloud-platform']});
const client=await auth.getClient();
console.log('Deployment principal: '+(client.email || 'federated service account'));
async function api(path,method='GET',data){
 try { return (await client.request({url:'https://firebasehosting.googleapis.com/v1beta1/'+path,method,data})).data; }
 catch(error){
  // Only Google API's public error description; never log the SDK error/request or auth headers.
  const detail=error.response?.data?.error;
  const reasons=(detail?.details || []).filter(d=>d['@type']==='type.googleapis.com/google.rpc.ErrorInfo').map(d=>({reason:d.reason,permission:d.metadata?.permission,service:d.metadata?.service,consumer:d.metadata?.consumer}));
  const failure=new Error(`Firebase Hosting API returned HTTP ${error.response?.status ?? 'unknown'} for ${method} ${path}. ${detail?.message || ''} ${JSON.stringify(reasons)}`);
  failure.status=error.response?.status;throw failure;
 }

}
async function ensure(path,createPath){
 try{return await api(path);}catch(error){if(error.status!==404)throw error;return api(createPath,'POST',{});}
}
try {
 await ensure(`projects/${project}/sites/${site}`,`projects/${project}/sites?siteId=${site}`);
 console.log(`Hosting site ready: ${site}`);
 try {
  const result=await ensure(`projects/${project}/sites/${site}/customDomains/${domain}`,`projects/${project}/sites/${site}/customDomains?customDomainId=${domain}`);
  const details=JSON.stringify(result,null,2);
  console.log('Custom domain status / DNS instructions:\n'+details);
  if(process.env.GITHUB_STEP_SUMMARY)await appendFile(process.env.GITHUB_STEP_SUMMARY,`\n### Custom domain setup\n\n\`\`\`json\n${details}\n\`\`\`\n`);
 }catch(error){console.log(`::warning::Custom domain setup remains pending: ${error.message}. Configure it in Firebase Hosting.`);}
} catch(error) { console.error(error.message);process.exitCode=1; }
