# Azure Development Deployment

Html2B uses three deliberate operator actions to create or recover its Azure
development environment:

1. preview and apply the complete infrastructure with Azure CLI and Bicep;
2. link the recreated deployment identity to the existing GitHub Environment;
3. dispatch the GitHub application workflow.

Bicep creates the resource group and the Azure resources required by the
application. It leaves Render on a public Azure quickstart container. The
application workflow builds the real Render image, applies the tracked
Container Apps configuration, and then deploys Functions. Html2B can be
unavailable between the Bicep Apply and successful application deployment.

This guide contains no environment-specific identifiers, resource names,
hostnames, release hashes, image digests, deployment outputs, or credentials.
Resolve those values from the selected CLI contexts, tracked parameters, and
command output while operating the environment.

## Repository Sources

- `bicep/main.bicep` is the subscription-scope infrastructure entry point.
- `bicep/environments/dev.bicepparam` contains the tracked development
  parameters.
- `bicep/modules/` contains the owned platform, identity, Functions, Render,
  and authentication resources.
- `scripts/azure/Set-GitHubIdentity.ps1` performs only the GitHub identity-link
  step.
- `deployment/azure/render-app.yaml` is the complete real Render revision
  configuration.
- `.github/workflows/daploy-azure.yml` builds and deploys the application.

The Microsoft Entra application used to protect Render and the GitHub
Environment are external prerequisites. They are not created by Bicep and are
not removed when the Azure resource group is deleted.

## Prerequisites

- PowerShell 7.3 or later.
- Git.
- .NET 10 SDK.
- Azure CLI with Bicep.
- GitHub CLI.
- An authenticated `az` session with permission to deploy the resources and
  role assignments described by the template.
- An authenticated `gh` session with permission to update variables and run
  workflows in the selected repository and Environment.
- An existing Render Microsoft Entra application and GitHub Environment that
  match the tracked configuration.
- A clean, retrievable source revision on a branch allowed by the GitHub
  Environment.

Keep identifiers, CLI output, keys, tokens, connection strings, and generated
artifacts in memory or ignored operator output. Do not add them to source or
documentation.

## Validate the Source

Run from the repository root:

```powershell
git status --short
git rev-parse HEAD

dotnet restore src/api/Html2b.slnx
dotnet build src/api/Html2b.slnx --configuration Release --no-restore
dotnet test src/api/Html2b.slnx --configuration Release --no-build
dotnet format src/api/Html2b.slnx --verify-no-changes --no-restore

az bicep build `
    --file bicep/main.bicep `
    --stdout `
    --only-show-errors |
    Out-Null

az bicep build-params `
    --file bicep/environments/dev.bicepparam `
    --stdout `
    --only-show-errors |
    Out-Null
```

Stop if the selected source is not the intended clean revision or any relevant
check fails. Do not substitute a locally modified workflow for the revision
that GitHub will run.

## Select and Verify the Operator Context

Collect the intended values in the current PowerShell session. The values
below are prompts, not repository defaults:

```powershell
$subscriptionId = Read-Host 'Azure subscription ID'
$location = Read-Host 'Azure deployment location'
$deploymentName = Read-Host 'Azure deployment name'
$resourceGroup = Read-Host 'Azure resource group name'
$deploymentIdentity = Read-Host 'Azure deployment identity name'
$repository = Read-Host 'GitHub repository in owner/name form'
$environmentName = Read-Host 'GitHub Environment name'
$sourceRef = Read-Host 'Git branch or tag to deploy'

az account set --subscription $subscriptionId
az account show --output table
gh auth status
gh repo view $repository
```

Verify the active Azure subscription, GitHub account, repository, Environment,
source ref, and intended resource group before any write. The identity-link
script repeats the Azure and GitHub target checks before changing the fixed
`AZURE_INFRA_CLIENT_ID` Environment variable.

## Preview and Apply Bicep

Preview the complete subscription deployment:

```powershell
az deployment sub what-if `
    --subscription $subscriptionId `
    --name $deploymentName `
    --location $location `
    --template-file bicep/main.bicep `
    --parameters bicep/environments/dev.bicepparam `
    --result-format FullResourcePayloads `
    --only-show-errors
```

Review every Create, Modify, Delete, and Ignore entry. Confirm the deployment
targets only the intended resource group and required children. Stop on an
unexpected resource, unexplained deletion, role expansion, or
credential-shaped output.

Apply the exact template, parameters, location, subscription, and deployment
name that were reviewed:

```powershell
az deployment sub create `
    --subscription $subscriptionId `
    --name $deploymentName `
    --location $location `
    --template-file bicep/main.bicep `
    --parameters bicep/environments/dev.bicepparam `
    --only-show-errors
```

Read the deployment and resource group back before continuing. Bicep creates
Render with the Azure quickstart image and bootstrap port. That revision proves
the Container App can start; it is not Html2B readiness. Applying Bicep again
also intentionally returns Render to this bootstrap configuration, so run the
application workflow afterward whenever Html2B must be restored.

## Link the Recreated Identity

Run the link script only after Bicep succeeds:

```powershell
pwsh scripts/azure/Set-GitHubIdentity.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroup `
    -DeploymentIdentityName $deploymentIdentity `
    -Repository $repository `
    -EnvironmentName $environmentName
```

The script does not sign in, deploy Bicep, build an artifact, or dispatch a
workflow. It validates the existing `az` and `gh` sessions, resolves the
recreated identity, writes only `AZURE_INFRA_CLIENT_ID` in the selected GitHub
Environment, and verifies the saved value. If it fails, correct the active CLI
session, permissions, or target values and rerun only this step.

## Deploy the Application

Dispatch the tracked application workflow from the clean source ref:

```powershell
gh workflow run daploy-azure.yml `
    --repo $repository `
    --ref $sourceRef `
    -f "target_environment=$environmentName"
```

Monitor the resulting run and record its non-secret run and source identity.
The workflow:

1. builds the Functions package from the selected source;
2. signs in to Azure with GitHub OIDC and the linked deployment identity;
3. builds the Render image in Azure Container Registry using the exact source
   revision as its tag;
4. resolves the immutable image digest;
5. substitutes only that digest, the Render identity resource ID, and the
   registry server into a temporary copy of the tracked Render YAML;
6. applies the complete Render configuration; and
7. deploys Functions last.

The workflow never invokes Bicep. It preserves Render authentication and
applies port 8080, the health probes, resources, scale settings, identity,
registry, secure ingress, and single-revision traffic from the tracked YAML.

## Verify the Deployment

After the workflow succeeds, verify:

- all expected Azure resources report a successful state;
- the deployment identity has the exact GitHub federation, resource-group
  Contributor, and repository-conditioned registry Writer assignment;
- the Render identity has only its repository-conditioned registry Reader;
- the source tag resolves to the immutable digest used by the active Render
  revision;
- the live Container App matches `deployment/azure/render-app.yaml`;
- Render authentication requires HTTPS, permits the Function identity, and
  rejects anonymous direct access;
- Azure discovers the liveness, readiness, and render Functions;
- anonymous Function liveness succeeds; and
- authorized readiness and PNG, JPEG, and PDF requests return their expected
  status, media type, file signature, and dimensions.

Reading or using a Function key is a separate credential-access action. Keep
an approved key in memory only, never print or persist it, and clear local
buffers after verification.

## Recover from a Partial Failure

There is no automatic rollback. Recover the failed boundary, then continue in
order:

- If Bicep is incomplete, inspect the failed deployment and a fresh What-If.
  Correct the cause and reapply Bicep until the owned graph converges.
- If identity linking fails, correct the CLI context, permissions, or selected
  target and rerun only the link script.
- If image build or Render deployment fails, keep the quickstart revision or
  last accepted revision, diagnose the failure, and rerun the same reviewed
  application source.
- If Functions deployment fails after Render succeeds, diagnose the Functions
  boundary and rerun the same reviewed application source so both hosts retain
  a traceable release identity.
- If Bicep is applied after an application release, rerun the link step when
  the deployment identity changed, then rerun application deployment to replace
  the intentional quickstart configuration.

Do not create a broader identity, disable authentication, expose credentials,
or delete additional resources as a recovery shortcut.

## Destructive Recreation

Deleting the application resource group removes the deployment identity and
its Azure role assignments together with the application resources. GitHub
cannot deploy again until Bicep recreates the identity and the link script
updates the existing GitHub Environment.

Treat deletion as a separate destructive operation:

1. retain the exact retrievable source revision and required non-secret
   configuration outside the resource group;
2. verify the active subscription and resolve the exact resource-group ID;
3. verify the external Render application and GitHub Environment;
4. obtain explicit authorization for that exact resource-group deletion;
5. delete only the resolved group and wait until it is absent; and
6. run Bicep, identity linking, and application deployment as three separate
   actions, reviewing each target before its write.

Resource-group deletion is not rollback. Deleted resource-group data is not
recoverable through this procedure. Git operations, role changes outside the
template, credential reads, workflow dispatch, and any additional deletion
remain separate actions.

## Development Deployment Limits

- Both hosts use public HTTPS endpoints. Render is identity-protected but is
  not network-private.
- Render scales to zero. Chromium startup can temporarily return
  `503` or not-ready responses before readiness converges.
- The quickstart interval and deployment failures can leave Html2B unavailable
  until the application workflow succeeds.
- Azure endpoints, retained images, Functions execution, logging, and telemetry
  can incur charges.
- The service renders server-owned HTML. It is not an isolation boundary for
  caller-authored HTML or arbitrary caller-selected network and file access.
- A Function key is a shared caller credential for protected Function routes;
  it is not end-user identity or browser authentication.
