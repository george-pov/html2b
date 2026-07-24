# Html2B

Html2B is an online service for generating thumbnails and other static images from reusable HTML and CSS templates.

Users create one or more templates using regular HTML, inline CSS, and replaceable tokens such as `{{ title }}`. A template can define text fields, reference uploaded images and other assets, and render them as a static web page. Html2B captures that page at a requested size and exports the result as PNG, JPEG, PDF, or another supported format.

The primary use case is generating thumbnail images for YouTube streams, but the same approach can support social media graphics, banners, reports, certificates, and other consistently rendered content.

> [!NOTE]
> Html2B is currently an early-stage project. The API and implementation details described below are the intended direction and may change as the project develops.

## Containerized rendering POC

The repository includes a local proof of concept under `src/api` that runs one
public .NET isolated Functions host and one private ASP.NET Core Render host.
The Functions host runs through Azure Functions Core Tools on Windows. Docker
Compose runs Render and its Playwright-managed Chromium browser with a
loopback-only binding. The POC renders one trusted, server-owned HTML document
at 1280 by 720 and returns PNG, JPEG, or PDF bytes without persisting output.

### Windows prerequisites

The verified Windows setup uses:

- WSL 2.1.5 or later.
- Docker Desktop with the WSL 2 backend and Linux container mode.
- Docker Compose v2.
- The .NET 10 SDK.
- Azure Functions Core Tools 4.

Verify an existing workstation from PowerShell:

```powershell
wsl --version
wsl --list --verbose
dotnet --list-sdks
func --version
docker version
docker compose version
docker info --format '{{.OSType}}'
docker run --rm hello-world
```

Docker Desktop installation and licensing remain the workstation owner's
responsibility. The container image already contains Chromium and its Linux
dependencies; do not install Chromium or Playwright browsers on the Windows
host. Azure CLI is not required for this POC.

### Run locally

From the repository root, build and start the private Render service:

```powershell
docker compose up --build html2b-render
```

Compose publishes Render only at `127.0.0.1:8081`; it is not bound to the LAN.
For Visual Studio debugging, create the ignored local Functions settings file
once:

```powershell
Copy-Item `
    src/api/Html2b.AzureFunctions/local.settings.sample.json `
    src/api/Html2b.AzureFunctions/local.settings.json
```

In the copied `local.settings.json`, set
`RenderService__BaseUrl` to `http://localhost:8081`; the tracked sample keeps a
placeholder value.

Visual Studio 2026 can start both processes with one F5:

1. Open `src/api/Html2b.slnx`.
2. Select the shared `Html2b local` launch profile.
3. Press F5. Visual Studio starts `Html2b.Render` in its Linux Docker container
   on `127.0.0.1:8081` and starts `Html2b.AzureFunctions` on the Windows host at
   `http://localhost:8080`.

Run `docker compose down` first if a manually started Compose container already
owns port 8081.

If the container runtime is stopped, configure **Tools > Options > Container
Tools > General > Start the container runtime if needed** to start it
automatically.

To run without Visual Studio, start the public Functions host in a second
terminal:

```powershell
$env:FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
$env:RenderService__BaseUrl = 'http://localhost:8081'
Push-Location src/api/Html2b.AzureFunctions
func start --port 8080
Pop-Location
```

The public API listens over HTTP at `http://localhost:8080`. In a third
terminal, check process liveness and end-to-end browser readiness:

```powershell
Invoke-WebRequest http://localhost:8080/health/live
Invoke-WebRequest http://localhost:8080/health/ready
```

Stop Core Tools with Ctrl+C. Then stop the private Render service and its local
Compose network:

```powershell
docker compose down
```

The image runs Render as the non-root `pwuser` under `tini`, includes a Docker
liveness health check, and gives the hosted browser up to 30 seconds to shut
down cleanly. The API-to-Render call is a temporary bounded private HTTP bridge:
each render has a 75-second budget and a 16 MiB response cap.

### POC endpoints

Every render request is a bodyless POST using fixed server-side HTML and output
settings.

| Method and route | Successful response |
| --- | --- |
| `GET /health/live` | HTTP 200 with `{"status":"live"}` while the API process is running |
| `GET /health/ready` | HTTP 200 with `{"status":"ready"}` when Chromium is connected; otherwise HTTP 503 with `{"status":"not-ready"}` |
| `POST /api/renders/png` | `image/png`; attachment `html2b-poc.png` |
| `POST /api/renders/jpeg` | `image/jpeg`; attachment `html2b-poc.jpg` |
| `POST /api/renders/pdf` | `application/pdf`; attachment `html2b-poc.pdf` |

For example:

```powershell
Invoke-WebRequest -Method Post -Uri http://localhost:8080/api/renders/png -OutFile html2b-poc.png
Invoke-WebRequest -Method Post -Uri http://localhost:8080/api/renders/jpeg -OutFile html2b-poc.jpg
Invoke-WebRequest -Method Post -Uri http://localhost:8080/api/renders/pdf -OutFile html2b-poc.pdf
```

Other format values return HTTP 400 problem details listing `png`, `jpeg`, and
`pdf` as the supported values. Render reuses one hosted browser, permits one
active render at a time, and creates a fresh restricted browser context and
page for every request.

### POC limitations

- HTML, text, dimensions, JPEG quality, and PDF settings are hardcoded. The POC
  does not accept templates, tokens, caller HTML, uploads, URLs, or assets.
- JavaScript, service workers, downloads, and HTTP or HTTPS page requests are
  blocked. Output remains in memory and is not persisted.
- The synchronous private HTTP request and in-memory relay are transitional.
  No queue, job store, Blob output, or durable retry exists yet.
- The approved POC has no automated test project; its API, output, browser, and
  container lifecycle were validated manually.
- The Playwright container launches Chromium with `--no-sandbox`. Combined
  with the lack of authentication, resource limits, and production isolation,
  this makes the image unsuitable as a sandbox for untrusted HTML.
- The Azure deployment described below is manual, development-only, public,
  and unauthenticated. It does not make the renderer safe for untrusted HTML or
  provide production availability.

## Azure dev deployment

> [!WARNING]
> Both Feature 004 hosts are public, unauthenticated, and development-only.
> Anyone who knows an endpoint can call it. Do not send secrets, personal data,
> proprietary HTML, or untrusted content. This POC has no production SLA,
> custom domain, authentication, private networking, backup, or multi-replica
> availability. The public endpoints, retained ACR images, Function resources,
> and Log Analytics ingestion can incur Azure charges.

Feature 004 uses a manually operated, two-host deployment in
`rg-html2b-dev` (`westus2`). `Html2b.AzureFunctions` is the public API host.
`Html2b.Render` is a separate public HTTPS Container App. Bicep passes the
generated Render HTTPS URL to the Function App as
`RenderService__BaseUrl`. No GitHub deployment automation, VNet, subnet,
private endpoint, or private DNS is part of this deployment.

The endpoints verified on July 24, 2026 are:

- Function API:
  [`https://func-html2b-api-dev.azurewebsites.net`](https://func-html2b-api-dev.azurewebsites.net)
- Render service:
  [`https://ca-html2b-render-dev.ashyisland-b79aded0.westus2.azurecontainerapps.io`](https://ca-html2b-render-dev.ashyisland-b79aded0.westus2.azurecontainerapps.io)

The current resource inventory is:

| Ownership | Resource | Name |
| --- | --- | --- |
| Shared/reused | Resource group | `rg-html2b-dev` |
| Shared/reused | Azure Container Registry | `crhtml2bdev` |
| Shared/reused | Log Analytics workspace | `log-html2b-dev` |
| Shared/reused | Container Apps environment | `cae-html2b-dev` |
| Feature 004 | Function storage account | `sthtml2bfuncdev` |
| Feature 004 | Private Function deployment container | `function-releases` |
| Feature 004 | Flex Consumption plan | `plan-html2b-functions-dev` |
| Feature 004 | Application Insights | `appi-html2b-dev` |
| Feature 004 | Function App | `func-html2b-api-dev` |
| Feature 004 | Render user-assigned identity | `id-html2b-render-dev` |
| Feature 004 | Render Container App | `ca-html2b-render-dev` |
| Retained legacy | Original runtime identity | `id-html2b-api-dev` |
| Retained legacy | Original single-host Container App | `ca-html2b-dev` |
| External legacy bootstrap state | Infrastructure identity | `id-html2b-infrastructure-dev` |

Application Insights also created its platform-managed Failure Anomalies smart
detector rule. The legacy `ca-html2b-dev` configuration was unchanged by the
Feature 004 release. The manual Feature 004 procedure does not use
`id-html2b-infrastructure-dev`.

### Verified release

The first complete two-host release is tied to one source commit and two
recorded artifacts:

| Item | Verified value |
| --- | --- |
| Source commit | `875aa3457020f3c7b96598052ce8ce52fe60faae` |
| Render image | `crhtml2bdev.azurecr.io/html2b-render@sha256:5889be38d28e7ee0bf2e8bdd2ce8e461674e384abb83ead022ca45a8741c6f1d` |
| Function ZIP SHA-256 | `96c75ba424759c3fe4d6831db7e0008a7546f69c56d6c41a049647c554d89dc8` |

The verified Function App is public, HTTPS-only, running .NET isolated `10.0`
on Flex Consumption with 2,048 MB instance memory and a maximum of one
instance. The Render app is public over HTTPS, rejects insecure serving, uses
1 vCPU and 2 GiB memory, scales from zero to one replica, and permits one
concurrent HTTP request per replica.

### Parameter sources

Do not commit subscription, tenant, or operator object IDs. Acquire them in
the signed-in session. Fixed dev values come from
`bicep/environments/dev.bicepparam`; source-specific values come from the clean
Git commit being released.

| Parameter or variable | Value | Source |
| --- | --- | --- |
| `$subscriptionId` | Selected at deployment time | Copy from `az account list` |
| `$deploymentOperatorPrincipalId` | Signed-in operator object ID | `az ad signed-in-user show --query id` |
| `$environmentName` | `dev` | `dev.bicepparam` |
| `$location` | `westus2` | `dev.bicepparam` |
| `$resourceGroupName` | `rg-html2b-dev` | `dev.bicepparam` |
| `$containerRegistryName` | `crhtml2bdev` | `dev.bicepparam` |
| `$imageRepositoryName` | `html2b-render` | `dev.bicepparam` |
| `$logAnalyticsWorkspaceName` | `log-html2b-dev` | `dev.bicepparam` |
| `$containerAppsEnvironmentName` | `cae-html2b-dev` | `dev.bicepparam` |
| `$functionStorageAccountName` | `sthtml2bfuncdev` | `dev.bicepparam` |
| `$functionPlanName` | `plan-html2b-functions-dev` | `dev.bicepparam` |
| `$applicationInsightsName` | `appi-html2b-dev` | `dev.bicepparam` |
| `$functionAppName` | `func-html2b-api-dev` | `dev.bicepparam` |
| `$functionDeploymentContainerName` | `function-releases` | `dev.bicepparam` |
| `$functionRuntime` | `dotnet-isolated` | `dev.bicepparam` |
| `$functionRuntimeVersion` | `10.0` | `dev.bicepparam` |
| `$functionInstanceMemoryMb` | `2048` | `dev.bicepparam` |
| `$functionMaximumInstanceCount` | `1` | `dev.bicepparam` |
| `$renderIdentityName` | `id-html2b-render-dev` | `dev.bicepparam` |
| `$renderContainerAppName` | `ca-html2b-render-dev` | `dev.bicepparam` |
| `$renderCpu` | `1` | `dev.bicepparam` |
| `$renderMemory` | `2Gi` | `dev.bicepparam` |
| `$renderMinReplicas` | `0` | `dev.bicepparam` |
| `$renderMaxReplicas` | `1` | `dev.bicepparam` |
| `$renderHttpConcurrency` | `1` | `dev.bicepparam` |
| `$sourceSha` | Full Git SHA | `git rev-parse HEAD` |
| `$containerImageTag` | ACR repository plus full Git SHA | Derived before the build |
| `$containerImage` | ACR repository plus manifest digest | Resolved after the build |
| `$deploymentName` | `html2b-dev-` plus the first 12 SHA characters | Derived before deployment |
| Function and Render host names | Generated by Azure | Bicep outputs and Azure readback |

### Prerequisites and local compilation

Use PowerShell 7, Git, `tar`, Azure CLI with Bicep, and the .NET 10 SDK.
The operator must be able to deploy subscription-scope Bicep, create the
planned resources and role assignments, and run ACR Tasks. The bootstrap
template grants repository-scoped image data access; it does not grant the
control-plane permission required to start `az acr build`.

The scripts under `scripts/azure/` still target the retired Feature 002
single-host deployment. Do not use them for Feature 004. Run the commands below
from the repository root.

```powershell
Set-Location C:\Projects\html2b

dotnet restore src/api/Html2b.slnx
dotnet build src/api/Html2b.slnx --configuration Release --no-restore

New-Item -ItemType Directory -Path build/validation/004/bicep -Force |
  Out-Null

az bicep build `
  --file bicep/main.bicep `
  --outfile build/validation/004/bicep/main.json

az bicep build `
  --file bicep/bootstrap.bicep `
  --outfile build/validation/004/bicep/bootstrap.json

az bicep build-params `
  --file bicep/environments/dev.bicepparam `
  --outfile build/validation/004/bicep/dev.parameters.json
```

Stop if the .NET build or any Bicep command fails.

### T006: Select the subscription and load parameters

Sign in, list subscriptions, and paste the intended subscription ID into the
placeholder. Never paste a real subscription or operator ID into this file.

```powershell
Set-Location C:\Projects\html2b

az login

az account list `
  --query "[].{Name:name,SubscriptionId:id,State:state}" `
  --output table

$subscriptionId = '<paste SubscriptionId from az account list>'

az account set --subscription $subscriptionId

az account show `
  --subscription $subscriptionId `
  --query "{Name:name,SubscriptionId:id,TenantId:tenantId,State:state}" `
  --output table

$deploymentOperatorPrincipalId = (
  az ad signed-in-user show --query id --output tsv
).Trim()

if ($deploymentOperatorPrincipalId -notmatch
    '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw 'Could not read the signed-in deployment operator object ID.'
}
```

Confirm the selected subscription is correct and its state is `Enabled`, then
load the compiled parameters and source-specific values:

```powershell
$deploymentParameters = Get-Content `
  build/validation/004/bicep/dev.parameters.json `
  -Raw | ConvertFrom-Json

$environmentName =
  $deploymentParameters.parameters.environmentName.value
$location = $deploymentParameters.parameters.location.value
$resourceGroupName =
  $deploymentParameters.parameters.resourceGroupName.value
$containerRegistryName =
  $deploymentParameters.parameters.containerRegistryName.value
$imageRepositoryName =
  $deploymentParameters.parameters.imageRepositoryName.value
$logAnalyticsWorkspaceName =
  $deploymentParameters.parameters.logAnalyticsWorkspaceName.value
$containerAppsEnvironmentName =
  $deploymentParameters.parameters.containerAppsEnvironmentName.value
$functionStorageAccountName =
  $deploymentParameters.parameters.functionStorageAccountName.value
$functionPlanName =
  $deploymentParameters.parameters.functionPlanName.value
$applicationInsightsName =
  $deploymentParameters.parameters.applicationInsightsName.value
$functionAppName =
  $deploymentParameters.parameters.functionAppName.value
$functionDeploymentContainerName =
  $deploymentParameters.parameters.functionDeploymentContainerName.value
$functionRuntime =
  $deploymentParameters.parameters.functionRuntime.value
$functionRuntimeVersion =
  $deploymentParameters.parameters.functionRuntimeVersion.value
$functionInstanceMemoryMb =
  $deploymentParameters.parameters.functionInstanceMemoryMb.value
$functionMaximumInstanceCount =
  $deploymentParameters.parameters.functionMaximumInstanceCount.value
$renderIdentityName =
  $deploymentParameters.parameters.renderIdentityName.value
$renderContainerAppName =
  $deploymentParameters.parameters.renderContainerAppName.value
$renderCpu = $deploymentParameters.parameters.renderCpu.value
$renderMemory = $deploymentParameters.parameters.renderMemory.value
$renderMinReplicas =
  $deploymentParameters.parameters.renderMinReplicas.value
$renderMaxReplicas =
  $deploymentParameters.parameters.renderMaxReplicas.value
$renderHttpConcurrency =
  $deploymentParameters.parameters.renderHttpConcurrency.value

$workingTreeChanges = @(git status --porcelain)
if ($workingTreeChanges.Count -ne 0) {
    throw 'The Git working tree must be clean before deployment.'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'git diff --check failed.'
}

$sourceSha = (git rev-parse HEAD).Trim()
if ($sourceSha -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not read a full Git commit SHA.'
}

$containerImageTag =
  "${containerRegistryName}.azurecr.io/${imageRepositoryName}:$sourceSha"
$deploymentName = "html2b-dev-$($sourceSha.Substring(0, 12))"
$functionPublishDirectory = "build/publish/functions-$sourceSha"
$functionZip = "build/publish/html2b-functions-$sourceSha.zip"
$releaseManifestPath =
  "build/validation/004/live/release-$sourceSha.json"

New-Item -ItemType Directory -Path build/validation/004/live -Force |
  Out-Null

[pscustomobject]@{
    SubscriptionId = $subscriptionId
    DeploymentOperatorPrincipalId = $deploymentOperatorPrincipalId
    SourceSha = $sourceSha
    DeploymentName = $deploymentName
    ContainerImageTag = $containerImageTag
    FunctionZip = $functionZip
} | Format-List
```

### T007: Verify the shared Azure resources

Every Azure resource command must explicitly target `$subscriptionId`.

```powershell
az group show `
  --subscription $subscriptionId `
  --name $resourceGroupName `
  --query "{Name:name,Location:location,State:properties.provisioningState}" `
  --output table

az acr show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $containerRegistryName `
  --query "{Name:name,LoginServer:loginServer,RoleAssignmentMode:roleAssignmentMode,State:provisioningState}" `
  --output table

az monitor log-analytics workspace show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --workspace-name $logAnalyticsWorkspaceName `
  --query "{Name:name,Location:location,State:provisioningState}" `
  --output table

az containerapp env show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $containerAppsEnvironmentName `
  --query "{Name:name,Location:location,State:properties.provisioningState}" `
  --output table
```

The resource group, ACR, Log Analytics workspace, and Container Apps
environment must exist in `westus2` with `Succeeded` state. ACR
`RoleAssignmentMode` must be `AbacRepositoryPermissions`.

For an initial deployment, the Function storage name must be globally
available. For a repeat deployment of this environment, it must already exist
in the expected resource group:

```powershell
$functionStorage = az storage account show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $functionStorageAccountName `
  --query "{Name:name,Location:location,State:provisioningState}" `
  --output json 2>$null

if ($LASTEXITCODE -eq 0) {
    $functionStorage | ConvertFrom-Json | Format-List
}
else {
    az storage account check-name `
      --subscription $subscriptionId `
      --name $functionStorageAccountName `
      --query "{Available:nameAvailable,Reason:reason,Message:message}" `
      --output yaml
}
```

Before applying, record the retained legacy app configuration so it can be
compared after deployment:

```powershell
$legacyAppBeforePath =
  'build/validation/004/live/legacy-app-before.json'

az containerapp show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name ca-html2b-dev `
  --query "{Name:name,Location:location,State:properties.provisioningState,Identity:identity,Ingress:properties.configuration.ingress,Template:properties.template,Tags:tags,LatestRevision:properties.latestRevisionName,LatestReadyRevision:properties.latestReadyRevisionName}" `
  --output json `
  --no-pretty-print |
  Set-Content -LiteralPath $legacyAppBeforePath -Encoding utf8

$legacyAppBeforeHash = (
  Get-FileHash -LiteralPath $legacyAppBeforePath -Algorithm SHA256
).Hash.ToLowerInvariant()
```

Stop if any shared resource is missing or unhealthy, the ACR is not in ABAC
repository-permissions mode, an initial storage name is unavailable, or the
existing storage account is not the expected Feature 004 resource.

### T008: Bootstrap ACR access and build Render

Validate and preview the repository-scoped Writer assignment. All JSON
What-If output uses `--no-pretty-print` so the saved evidence remains valid
JSON without ANSI formatting.

```powershell
$acrAccessDeploymentName = "$deploymentName-acr-access"

az deployment sub validate `
  --subscription $subscriptionId `
  --name "$acrAccessDeploymentName-validate" `
  --location $location `
  --template-file bicep/bootstrap.bicep `
  --parameters resourceGroupName=$resourceGroupName `
               containerRegistryName=$containerRegistryName `
               imageRepositoryName=$imageRepositoryName `
               deploymentOperatorPrincipalId=$deploymentOperatorPrincipalId `
  --only-show-errors

az deployment sub what-if `
  --subscription $subscriptionId `
  --name $acrAccessDeploymentName `
  --location $location `
  --template-file bicep/bootstrap.bicep `
  --parameters resourceGroupName=$resourceGroupName `
               containerRegistryName=$containerRegistryName `
               imageRepositoryName=$imageRepositoryName `
               deploymentOperatorPrincipalId=$deploymentOperatorPrincipalId `
  --result-format FullResourcePayloads `
  --output json `
  --no-pretty-print |
  Tee-Object -FilePath `
    build/validation/004/live/acr-access-what-if.json
```

Inspect the saved preview. It may create or converge exactly one
`Container Registry Repository Writer` role assignment at the existing ACR
scope, conditioned to `html2b-render` for the current operator. Stop if it
changes another resource, grants registry-wide access, or uses legacy
`AcrPush`/`AcrPull`.

Apply only after the bootstrap preview is accepted:

```powershell
az deployment sub create `
  --subscription $subscriptionId `
  --name $acrAccessDeploymentName `
  --location $location `
  --template-file bicep/bootstrap.bicep `
  --parameters resourceGroupName=$resourceGroupName `
               containerRegistryName=$containerRegistryName `
               imageRepositoryName=$imageRepositoryName `
               deploymentOperatorPrincipalId=$deploymentOperatorPrincipalId `
  --query properties.outputs `
  --output json |
  Tee-Object -FilePath `
    build/validation/004/live/acr-access-outputs.json
```

Build from a clean `git archive` of `$sourceSha`. Never pass the repository
root to `az acr build`; ignored local files are not covered by the clean
worktree check and must not enter the remote build context.

```powershell
$temporaryRoot = [System.IO.Path]::GetFullPath(
  [System.IO.Path]::GetTempPath())
$renderSourceArchive = Join-Path `
  $temporaryRoot `
  "html2b-render-$sourceSha.tar"
$renderBuildContext = Join-Path `
  $temporaryRoot `
  "html2b-render-$sourceSha"

foreach ($temporaryPath in @($renderSourceArchive, $renderBuildContext)) {
    $resolvedCandidate = [System.IO.Path]::GetFullPath($temporaryPath)
    if (-not $resolvedCandidate.StartsWith(
        $temporaryRoot,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Temporary path escaped the temporary directory: $temporaryPath"
    }
    if (Test-Path -LiteralPath $temporaryPath) {
        throw "Temporary deployment path already exists: $temporaryPath"
    }
}

New-Item -ItemType Directory -Path $renderBuildContext |
  Out-Null

try {
    git archive `
      --format=tar `
      --output=$renderSourceArchive `
      $sourceSha
    if ($LASTEXITCODE -ne 0) {
        throw "Could not archive Git commit $sourceSha."
    }

    tar -xf $renderSourceArchive -C $renderBuildContext
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not extract the clean Render build context.'
    }

    az acr build `
      --subscription $subscriptionId `
      --resource-group $resourceGroupName `
      --registry $containerRegistryName `
      --source-acr-auth-id '[caller]' `
      --image "${imageRepositoryName}:$sourceSha" `
      --file "$renderBuildContext/src/api/Html2b.Render/Dockerfile" `
      $renderBuildContext
    if ($LASTEXITCODE -ne 0) {
        throw 'The Render ACR build failed.'
    }
}
finally {
    if (Test-Path -LiteralPath $renderSourceArchive) {
        Remove-Item -LiteralPath $renderSourceArchive -Force
    }
    if (Test-Path -LiteralPath $renderBuildContext) {
        Remove-Item -LiteralPath $renderBuildContext -Recurse -Force
    }
}

$publishedTag = az acr repository show-tags `
  --subscription $subscriptionId `
  --name $containerRegistryName `
  --repository $imageRepositoryName `
  --query "[?@=='$sourceSha'] | [0]" `
  --output tsv

if ($publishedTag -ne $sourceSha) {
    throw "Render image tag $sourceSha was not found in ACR."
}

$containerImageDigest = (
  az acr manifest show-metadata `
    --subscription $subscriptionId `
    --registry $containerRegistryName `
    --name "${imageRepositoryName}:$sourceSha" `
    --query digest `
    --output tsv
).Trim()

if ($containerImageDigest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw 'Could not resolve the Render image manifest digest.'
}

$containerImage =
  "${containerRegistryName}.azurecr.io/${imageRepositoryName}@$containerImageDigest"

[pscustomobject]@{
    ContainerImageTag = $containerImageTag
    ContainerImage = $containerImage
} | Format-List
```

Stop if the build is unauthorized. Correct the missing control-plane
permission or the reviewed bootstrap Bicep; do not add a broad portal role as
an undocumented workaround. Bicep must receive the digest-qualified
`$containerImage`, never the mutable tag.

### T009: Validate, preview, and apply the two-host Bicep

Validate:

```powershell
az deployment sub validate `
  --subscription $subscriptionId `
  --name "$deploymentName-validate" `
  --location $location `
  --template-file bicep/main.bicep `
  --parameters "@build/validation/004/bicep/dev.parameters.json" `
               containerImage=$containerImage `
  --only-show-errors
```

Preview and save the full payload:

```powershell
az deployment sub what-if `
  --subscription $subscriptionId `
  --name $deploymentName `
  --location $location `
  --template-file bicep/main.bicep `
  --parameters "@build/validation/004/bicep/dev.parameters.json" `
               containerImage=$containerImage `
  --result-format FullResourcePayloads `
  --output json `
  --no-pretty-print |
  Tee-Object -FilePath `
    build/validation/004/live/deployment-what-if.json
```

Treat the full-payload file as potentially sensitive because ARM What-If may
expand values derived from resource functions. Keep it in the ignored
`build/validation/004/live/` directory and do not commit or share it without
inspection.

For the first deployment, the preview creates the Function storage, Flex plan,
Application Insights, Function App, Render identity, Render Container App, and
repository-scoped Reader role. Inspect the exact Render digest, 1 vCPU/2 GiB
sizing, 0-1 scaling, concurrency 1, external HTTPS ingress, Function memory
2,048 MB, maximum Function instances 1, generated Render URL, and resource
group tags.

Stop if the preview deletes a resource; changes `ca-html2b-dev`; replaces ACR,
Log Analytics, or the Container Apps environment; creates private-networking
resources; enables insecure public serving; or includes an unexpected role,
identity, image, or parameter.

Apply only after the saved preview is accepted:

```powershell
az deployment sub create `
  --subscription $subscriptionId `
  --name $deploymentName `
  --location $location `
  --template-file bicep/main.bicep `
  --parameters "@build/validation/004/bicep/dev.parameters.json" `
               containerImage=$containerImage `
  --query properties.outputs `
  --output json |
  Tee-Object -FilePath `
    build/validation/004/live/deployment-outputs.json
```

### T010: Publish the matching Function package

Recheck the source, publish the Function App, record the ZIP hash beside the
Render digest, and deploy the ZIP:

```powershell
if ((git rev-parse HEAD).Trim() -ne $sourceSha -or
    @(git status --porcelain).Count -ne 0) {
    throw 'Git changed after artifact identifiers were selected.'
}

if ((Test-Path -LiteralPath $functionPublishDirectory) -or
    (Test-Path -LiteralPath $functionZip)) {
    throw 'Function publish output already exists; use a clean artifact path.'
}

dotnet publish `
  src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj `
  --configuration Release `
  --no-restore `
  --output $functionPublishDirectory

if (-not (Test-Path "$functionPublishDirectory/host.json")) {
    throw 'host.json is not at the publish-output root.'
}

$publishedLocalSettings = @(
  Get-ChildItem `
    -LiteralPath $functionPublishDirectory `
    -Filter local.settings.json `
    -File `
    -Recurse
)
if ($publishedLocalSettings.Count -ne 0) {
    throw 'The Function publish output contains local.settings.json.'
}

Compress-Archive `
  -Path "$functionPublishDirectory/*" `
  -DestinationPath $functionZip `
  -CompressionLevel Optimal `
  -Force

$functionZipHash = (
  Get-FileHash -LiteralPath $functionZip -Algorithm SHA256
).Hash.ToLowerInvariant()

[ordered]@{
    sourceSha = $sourceSha
    containerImage = $containerImage
    functionZip = $functionZip
    functionZipSha256 = $functionZipHash
} |
  ConvertTo-Json |
  Set-Content -LiteralPath $releaseManifestPath -Encoding utf8

az functionapp deployment source config-zip `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $functionAppName `
  --src $functionZip `
  --timeout 600 `
  --output none
```

Keep the sanitized `release-$sourceSha.json` as the link between the clean Git
commit, immutable Render digest, and Function ZIP hash.

### T011: Verify both public hosts

Read the generated host names and Function configuration. Flex Consumption
values are under `properties.functionAppConfig`; the Function host name is
under `properties.defaultHostName`.

```powershell
$functionHostName = (
  az functionapp show `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query properties.defaultHostName `
    --output tsv
).Trim()

$renderHostName = (
  az containerapp show `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --name $renderContainerAppName `
    --query properties.configuration.ingress.fqdn `
    --output tsv
).Trim()

$configuredRenderUrl = (
  az functionapp config appsettings list `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query "[?name=='RenderService__BaseUrl'].value | [0]" `
    --output tsv
).Trim()

[pscustomobject]@{
    FunctionUrl = "https://$functionHostName"
    RenderUrl = "https://$renderHostName"
    ConfiguredRenderUrl = $configuredRenderUrl
} | Format-List
```

Verify Function, Render, and repository-role state:

```powershell
az functionapp show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $functionAppName `
  --query "{Name:name,State:properties.state,Host:properties.defaultHostName,HttpsOnly:properties.httpsOnly,PublicNetworkAccess:properties.publicNetworkAccess,Runtime:properties.functionAppConfig.runtime,ScaleAndConcurrency:properties.functionAppConfig.scaleAndConcurrency}" `
  --output yaml

az containerapp show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $renderContainerAppName `
  --query "{Name:name,State:properties.provisioningState,IngressExternal:properties.configuration.ingress.external,AllowInsecure:properties.configuration.ingress.allowInsecure,LatestRevision:properties.latestRevisionName,ReadyRevision:properties.latestReadyRevisionName,Image:properties.template.containers[0].image,Cpu:properties.template.containers[0].resources.cpu,Memory:properties.template.containers[0].resources.memory,MinReplicas:properties.template.scale.minReplicas,MaxReplicas:properties.template.scale.maxReplicas,HttpConcurrency:properties.template.scale.rules[0].http.metadata.concurrentRequests}" `
  --output yaml

$acrResourceId = (
  az acr show `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --name $containerRegistryName `
    --query id `
    --output tsv
).Trim()

$renderPrincipalId = (
  az identity show `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --name $renderIdentityName `
    --query principalId `
    --output tsv
).Trim()

az role assignment list `
  --subscription $subscriptionId `
  --scope $acrResourceId `
  --assignee-object-id $deploymentOperatorPrincipalId `
  --query "[?roleDefinitionName=='Container Registry Repository Writer'].{Role:roleDefinitionName,Scope:scope,Condition:condition,ConditionVersion:conditionVersion}" `
  --output yaml

az role assignment list `
  --subscription $subscriptionId `
  --scope $acrResourceId `
  --assignee-object-id $renderPrincipalId `
  --query "[?roleDefinitionName=='Container Registry Repository Reader'].{Role:roleDefinitionName,Scope:scope,Condition:condition,ConditionVersion:conditionVersion}" `
  --output yaml
```

Expected state:

- Function state is `Running`, HTTPS-only and public network access are
  enabled, runtime is `dotnet-isolated` `10.0`, instance memory is `2048`, and
  maximum instance count is `1`.
- Render state is `Succeeded`, external ingress is `true`,
  `AllowInsecure` is `false`, latest revision equals ready revision, and its
  image equals `$containerImage`.
- Render has 1 vCPU, 2 GiB memory, 0-1 replicas, and HTTP concurrency 1.
- `$configuredRenderUrl` equals `https://$renderHostName`.
- Exactly one repository-scoped Writer applies to the operator and one
  repository-scoped Reader applies to the Render identity; both conditions
  name only `html2b-render`.

Poll all four health endpoints inside one bounded 10-minute window. On timeout,
save Azure state and stop before the render request.

```powershell
$healthDeadline = [DateTimeOffset]::UtcNow.AddMinutes(10)

function Wait-HealthEndpoint {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [DateTimeOffset] $Deadline
    )

    $lastError = 'No response received.'

    do {
        try {
            return Invoke-RestMethod `
              -Uri $Uri `
              -Method Get `
              -TimeoutSec 30
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 5
        }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)

    throw "Timed out waiting for $Uri. Last error: $lastError"
}

try {
    $renderLive = Wait-HealthEndpoint `
      -Uri "https://$renderHostName/health/live" `
      -Deadline $healthDeadline
    $renderReady = Wait-HealthEndpoint `
      -Uri "https://$renderHostName/health/ready" `
      -Deadline $healthDeadline
    $live = Wait-HealthEndpoint `
      -Uri "https://$functionHostName/health/live" `
      -Deadline $healthDeadline
    $ready = Wait-HealthEndpoint `
      -Uri "https://$functionHostName/health/ready" `
      -Deadline $healthDeadline
}
catch {
    az functionapp show `
      --subscription $subscriptionId `
      --resource-group $resourceGroupName `
      --name $functionAppName `
      --query "{Name:name,State:properties.state,Host:properties.defaultHostName,FunctionAppConfig:properties.functionAppConfig}" `
      --output json `
      --no-pretty-print |
      Set-Content `
        -LiteralPath build/validation/004/live/timeout-function-state.json `
        -Encoding utf8

    az containerapp show `
      --subscription $subscriptionId `
      --resource-group $resourceGroupName `
      --name $renderContainerAppName `
      --query "{Name:name,State:properties.provisioningState,LatestRevision:properties.latestRevisionName,ReadyRevision:properties.latestReadyRevisionName,Image:properties.template.containers[0].image}" `
      --output json `
      --no-pretty-print |
      Set-Content `
        -LiteralPath build/validation/004/live/timeout-render-state.json `
        -Encoding utf8

    throw
}
```

Verify one PNG through Functions:

```powershell
$renderOutput = "build/validation/004/live/render-$sourceSha.png"
$renderResponse = Invoke-WebRequest `
  -Uri "https://$functionHostName/api/renders/png" `
  -Method Post `
  -OutFile $renderOutput `
  -PassThru

$pngBytes = [System.IO.File]::ReadAllBytes($renderOutput)
if ($pngBytes.Length -lt 8) {
    throw 'Render response is too short to contain a PNG signature.'
}

[pscustomobject]@{
    RenderLive = $renderLive.status
    RenderReady = $renderReady.status
    FunctionLive = $live.status
    FunctionReady = $ready.status
    RenderHttpStatus = $renderResponse.StatusCode
    RenderContentType = $renderResponse.Headers.'Content-Type'
    RenderBytes = $pngBytes.Length
    PngSignature = [BitConverter]::ToString($pngBytes[0..7])
} | Format-List
```

Expected health values are `live`, `ready`, `live`, and `ready`. The render
request must return `200`, `image/png`, a non-empty body, and signature
`89-50-4E-47-0D-0A-1A-0A`.

Verify that public HTTP does not serve Render content:

```powershell
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)

try {
    $httpResponse = $client.GetAsync(
      "http://$renderHostName/health/live").GetAwaiter().GetResult()

    [pscustomobject]@{
        StatusCode = [int] $httpResponse.StatusCode
        Location = $httpResponse.Headers.Location
    } | Format-List

    if ([int] $httpResponse.StatusCode -eq 200) {
        throw 'Render unexpectedly served content over public HTTP.'
    }
}
finally {
    $client.Dispose()
    $handler.Dispose()
}
```

Finally, prove the retained legacy app is unchanged:

```powershell
$legacyAppAfterPath =
  'build/validation/004/live/legacy-app-after.json'

az containerapp show `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name ca-html2b-dev `
  --query "{Name:name,Location:location,State:properties.provisioningState,Identity:identity,Ingress:properties.configuration.ingress,Template:properties.template,Tags:tags,LatestRevision:properties.latestRevisionName,LatestReadyRevision:properties.latestReadyRevisionName}" `
  --output json `
  --no-pretty-print |
  Set-Content -LiteralPath $legacyAppAfterPath -Encoding utf8

$legacyAppAfterHash = (
  Get-FileHash -LiteralPath $legacyAppAfterPath -Algorithm SHA256
).Hash.ToLowerInvariant()

if ($legacyAppAfterHash -ne $legacyAppBeforeHash) {
    throw 'The retained ca-html2b-dev configuration changed.'
}
```

### Repeat What-If

After a successful release, rerun and save the full-payload preview with the
same digest:

```powershell
az deployment sub what-if `
  --subscription $subscriptionId `
  --name "$deploymentName-repeat" `
  --location $location `
  --template-file bicep/main.bicep `
  --parameters "@build/validation/004/bicep/dev.parameters.json" `
               containerImage=$containerImage `
  --result-format FullResourcePayloads `
  --output json `
  --no-pretty-print |
  Tee-Object -FilePath `
    "build/validation/004/live/repeat-what-if-$sourceSha.json"
```

Inspect exact property deltas. ARM What-If can report false-positive
modifications for provider defaults, generated identity properties, and values
derived from `listKeys()`. The verified first repeat preview reported no
deletes, no `ca-html2b-dev` changes, and no private-networking changes, but it
did report provider-derived noise on the Reader assignment, Render identity,
storage blob resources, and Function App. Do not treat a reported `Modify` as
safe without reviewing its property-level delta.

### Rollback

The July 24 release is the first complete release in which both artifacts use
the current HTTPS two-host contract. There is no prior matching full release
to restore. The rollback procedure is recorded now, but a live rollback drill
must wait until a later complete release has been deployed and this release is
its valid previous target. Do not use a pre-Feature 004 commit as a substitute.

For a future rollback, rebuild both artifacts from the exact previous deployed
Git commit. Do not depend on an old local ZIP, mutable image tag, repository
root build context, or traffic-only edit.

Prepare the rollback artifacts from a clean `git archive`:

```powershell
$previousSha = '<previous deployed 40-character Git SHA>'
if ($previousSha -notmatch '^[0-9a-f]{40}$') {
    throw 'Rollback requires a full previous Git commit SHA.'
}

git cat-file -e "$previousSha^{commit}"
if ($LASTEXITCODE -ne 0) {
    throw "Git commit $previousSha is not available locally."
}

$temporaryRoot = [System.IO.Path]::GetFullPath(
  [System.IO.Path]::GetTempPath())
$rollbackArchive = Join-Path `
  $temporaryRoot `
  "html2b-rollback-$previousSha.tar"
$rollbackSourceDirectory = Join-Path `
  $temporaryRoot `
  "html2b-rollback-$previousSha"

foreach ($temporaryPath in @($rollbackArchive, $rollbackSourceDirectory)) {
    $resolvedCandidate = [System.IO.Path]::GetFullPath($temporaryPath)
    if (-not $resolvedCandidate.StartsWith(
        $temporaryRoot,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Rollback path escaped the temporary directory: $temporaryPath"
    }
    if (Test-Path -LiteralPath $temporaryPath) {
        throw "Rollback path already exists: $temporaryPath"
    }
}

$previousFunctionPublishDirectory =
  "build/rollback/functions-$previousSha"
$previousFunctionZip =
  "build/rollback/html2b-functions-$previousSha.zip"
$rollbackDeploymentName =
  "html2b-rollback-$($previousSha.Substring(0, 12))"

New-Item -ItemType Directory -Path $rollbackSourceDirectory |
  Out-Null

try {
    git archive `
      --format=tar `
      --output=$rollbackArchive `
      $previousSha
    if ($LASTEXITCODE -ne 0) {
        throw "Could not archive rollback commit $previousSha."
    }

    tar -xf $rollbackArchive -C $rollbackSourceDirectory
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not extract the clean rollback source.'
    }

    az acr build `
      --subscription $subscriptionId `
      --resource-group $resourceGroupName `
      --registry $containerRegistryName `
      --source-acr-auth-id '[caller]' `
      --image "${imageRepositoryName}:rollback-$previousSha" `
      --file "$rollbackSourceDirectory/src/api/Html2b.Render/Dockerfile" `
      $rollbackSourceDirectory
    if ($LASTEXITCODE -ne 0) {
        throw 'The rollback Render build failed.'
    }

    $previousImageDigest = (
      az acr manifest show-metadata `
        --subscription $subscriptionId `
        --registry $containerRegistryName `
        --name "${imageRepositoryName}:rollback-$previousSha" `
        --query digest `
        --output tsv
    ).Trim()

    if ($previousImageDigest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Could not resolve the rollback image manifest digest.'
    }

    $previousImage =
      "${containerRegistryName}.azurecr.io/${imageRepositoryName}@$previousImageDigest"

    dotnet restore `
      "$rollbackSourceDirectory/src/api/Html2b.slnx"
    if ($LASTEXITCODE -ne 0) {
        throw 'Rollback restore failed.'
    }

    dotnet publish `
      "$rollbackSourceDirectory/src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj" `
      --configuration Release `
      --no-restore `
      --output $previousFunctionPublishDirectory
    if ($LASTEXITCODE -ne 0) {
        throw 'Rollback Function publish failed.'
    }

    if (-not (Test-Path "$previousFunctionPublishDirectory/host.json")) {
        throw 'Rollback host.json is not at the publish-output root.'
    }

    $rollbackLocalSettings = @(
      Get-ChildItem `
        -LiteralPath $previousFunctionPublishDirectory `
        -Filter local.settings.json `
        -File `
        -Recurse
    )
    if ($rollbackLocalSettings.Count -ne 0) {
        throw 'Rollback Function output contains local.settings.json.'
    }

    Compress-Archive `
      -Path "$previousFunctionPublishDirectory/*" `
      -DestinationPath $previousFunctionZip `
      -CompressionLevel Optimal `
      -Force

    $previousFunctionZipHash = (
      Get-FileHash -LiteralPath $previousFunctionZip -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    [ordered]@{
        sourceSha = $previousSha
        containerImage = $previousImage
        functionZip = $previousFunctionZip
        functionZipSha256 = $previousFunctionZipHash
    } |
      ConvertTo-Json |
      Set-Content -LiteralPath `
        "build/validation/004/live/rollback-release-$previousSha.json" `
        -Encoding utf8
}
finally {
    if (Test-Path -LiteralPath $rollbackArchive) {
        Remove-Item -LiteralPath $rollbackArchive -Force
    }
    if (Test-Path -LiteralPath $rollbackSourceDirectory) {
        Remove-Item `
          -LiteralPath $rollbackSourceDirectory `
          -Recurse `
          -Force
    }
}
```

Preview the rollback in its own command block:

```powershell
az deployment sub what-if `
  --subscription $subscriptionId `
  --name $rollbackDeploymentName `
  --location $location `
  --template-file bicep/main.bicep `
  --parameters "@build/validation/004/bicep/dev.parameters.json" `
               containerImage=$previousImage `
  --result-format FullResourcePayloads `
  --output json `
  --no-pretty-print |
  Tee-Object -FilePath `
    "build/validation/004/live/rollback-what-if-$previousSha.json"
```

Stop here. Inspect the saved full payload and obtain approval before either
live mutation. The preview must not delete resources, change the retained
legacy app, introduce private networking, or select an unexpected image.

Only after that review, apply the Bicep and deploy the rebuilt Function ZIP:

```powershell
az deployment sub create `
  --subscription $subscriptionId `
  --name $rollbackDeploymentName `
  --location $location `
  --template-file bicep/main.bicep `
  --parameters "@build/validation/004/bicep/dev.parameters.json" `
               containerImage=$previousImage `
  --output none

az functionapp deployment source config-zip `
  --subscription $subscriptionId `
  --resource-group $resourceGroupName `
  --name $functionAppName `
  --src $previousFunctionZip `
  --timeout 600 `
  --output none
```

Set `$sourceSha` to `$previousSha` and `$containerImage` to `$previousImage`,
then rerun every T011 state, role, health, render, public-HTTP, and retained-app
check. Keep the rollback manifest, preview, Function ZIP hash, and Render
digest as evidence. Do not delete failed revisions or ACR images as part of
rollback.

## How it works

1. Create an HTML template with inline styles and replaceable tokens.
2. Define the text fields and image assets available to the template.
3. Provide values for those fields and assets when requesting an image.
4. Select the target dimensions, output format, and optional file-size limit.
5. Html2B renders the template in Chromium and captures the result.

For example, a template could contain:

```html
<main style="width: 1280px; height: 720px; position: relative; overflow: hidden;">
    <img
        src="{{ backgroundImage }}"
        alt=""
        style="width: 100%; height: 100%; object-fit: cover;"
    />
    <h1 style="position: absolute; left: 64px; bottom: 48px; color: white;">
        {{ title }}
    </h1>
</main>
```

The render request supplies values for `backgroundImage` and `title`. Html2B replaces the tokens, loads the resulting page, and captures it using the requested output settings.

## Core concepts

### Templates

A template is a reusable HTML document with inline CSS. It can contain tokens in the form `{{ token }}` that are replaced with supplied values before rendering.

### Fields and assets

Templates can be linked to inputs such as:

- Text fields for titles, labels, dates, or other content.
- Image assets for backgrounds, logos, portraits, or overlays.
- Other asset types supported by the rendering pipeline in the future.

Templates reference these inputs through tokens, allowing the same design to be rendered with different content.

### Render settings

Each render can define:

- Target width and height.
- Output format, initially PNG, JPEG, or PDF.
- Output quality where the selected format supports it.
- A target file-size limit, where practical for the selected format.

## Proposed architecture

Html2B is expected to run as an API hosted in Azure Container Apps. The initial rendering pipeline will use Playwright with Chromium in a Linux container:

```text
API request
    -> load template and assets
    -> validate and replace tokens
    -> render HTML in Chromium
    -> capture screenshot or PDF
    -> optimize output
    -> return or store the generated file
```

The service will be built on .NET. Production projects will live under `src/api` and `src/ui`.

## Initial scope

The first useful version is expected to support:

- Creating and updating reusable templates.
- Defining text and image inputs for a template.
- Rendering templates through an HTTP API.
- Configurable output dimensions.
- PNG, JPEG, and PDF output.
- Image quality and file-size optimization.
- Linux container deployment with Playwright and Chromium.
- Deployment to Azure Container Apps.

Possible later capabilities include template versioning, a browser-based template editor and preview, batch rendering, additional output formats, storage integrations, and event-driven generation.

## Security considerations

Rendering user-authored HTML is a security-sensitive operation. The service will need strict isolation, resource and execution limits, controlled network access, input validation, and safe asset handling before it can accept untrusted templates.

## License

No license has been selected yet.
