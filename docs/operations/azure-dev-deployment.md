# Azure Development Deployment

Html2B uses an operator-driven Azure release. Bicep provisions the application
infrastructure, Azure Container Registry builds the Render image, and the
Functions package is deployed separately. Each changed artifact is produced
from clean source and recorded with its immutable identity. A Function-only
release retains and revalidates the deployed immutable Render image; a release
that changes both hosts builds both artifacts from the same clean revision.

This guide intentionally contains no environment-specific identifiers,
resource names, hostnames, release hashes, artifact digests, or deployment
outputs. Resolve those values from the selected Azure context, tracked
environment parameters, and command output during the release.

## Repository Sources

- `bicep/main.bicep` composes the application infrastructure.
- `bicep/bootstrap.bicep` configures repository-scoped registry access for the
  signed-in operator when that access is absent.
- `bicep/environments/dev.bicepparam` contains tracked development parameters.
- `bicep/modules/` contains the Functions and Render resource definitions.
- `src/api/Html2b.Render/Dockerfile` builds the Render image.
- `src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj` builds the
  Functions package.
- `scripts/azure/Test-AzureDev.ps1` validates the current two-host
  authentication, health, output, and Azure resource contracts.

The deployment uses existing shared registry, logging, and Container Apps
environment resources. The application templates create or update the
Functions resources and system identity, Render user-assigned image-pull
identity and Container App, Container Apps authentication, and required
repository-scoped image access.
The tracked environment parameters supply the non-secret Render API client ID;
the Microsoft Entra app registration and service principal already exist.

`scripts/azure/Deploy-AzureDev.ps1` and
`scripts/azure/Publish-Html2bImage.ps1` do not support the current
Functions-plus-Render topology and are not release commands for it.

## Prerequisites

- PowerShell 7.3 or later.
- Git.
- .NET 10 SDK.
- Azure CLI with Bicep.
- An Azure CLI session with permission to validate and apply the templates,
  build in the registry, publish the Functions package, and manage the required
  registry data role assignments.
- Permission to read the existing Function host key during validation.
- A clean Git working tree at the source revision being released.

Keep subscription, tenant, operator, resource, host, and artifact values in the
operator's session or ignored release output. Do not add them to source files
or this guide.

Function keys and access tokens remain process-local. Never print them, place
them in process arguments, save them in release output, or add them to
documentation or source.

## Validate the Repository Sources

From the repository root:

```powershell
dotnet restore src/api/Html2b.slnx
dotnet build src/api/Html2b.slnx --configuration Release --no-restore
dotnet test src/api/Html2b.slnx --configuration Release --no-build
dotnet format src/api/Html2b.slnx --verify-no-changes --no-restore

az bicep build --file bicep/main.bicep --stdout | Out-Null
az bicep build --file bicep/bootstrap.bicep --stdout | Out-Null
az bicep build-params `
    --file bicep/environments/dev.bicepparam `
    --stdout |
    Out-Null
```

Stop if restore, build, tests, formatting, or Bicep compilation fails.

## Select and Verify the Azure Context

1. Sign in with Azure CLI.
2. List the available subscriptions.
3. Select the development subscription in the local shell.
4. Read the active account back from Azure CLI and verify it before continuing.
5. Resolve the signed-in operator identity only in the local shell.
6. Confirm that the shared resources referenced by the tracked environment
   parameters exist.
7. Read the Render API client ID from the selected tracked environment
   parameters without copying it into this guide.

Do not copy values returned by these checks into documentation or tracked
files.

## Verify the Authentication Inputs

The deployment derives the Functions setting `RenderService__Audience` as
`api://<render-api-client-id>`. Infrastructure requests the corresponding
`api://<render-api-client-id>/.default` scope with the Function host's
system-assigned managed identity.

Container Apps authentication uses the version 2 tenant issuer, validates the
GUID client ID as the token audience, and permits the configured Function
principal. It has no excluded paths. Confirm those shapes from the compiled
template and selected Azure context without saving identifier values in
tracked output.

## Choose the Release Shape

- For a Function-only change, retain the currently deployed immutable Render
  image, revalidate its digest and live state, and build only the Functions ZIP
  from its exact clean source.
- When Render changes, build a new immutable Render image. When both hosts
  change together, build the image and Functions ZIP from the same clean
  revision.

Record the selected image digest, Functions source revision, ZIP checksum, and
their verified compatibility in ignored release output.

## Prepare the Render Image

Perform these steps only when the release changes Render:

1. Create a clean source archive from the exact Git revision being released.
2. Build the Render Dockerfile through Azure Container Registry using that
   clean archive as the build context.
3. Tag the build with the full source revision.
4. Resolve the resulting immutable manifest digest from the registry.
5. Keep the source revision and resolved digest together in ignored release
   output.

Run the bootstrap template only when the signed-in operator lacks the required
repository-scoped registry data access. Supply the operator identity at
execution time and inspect the role scope before applying it.

## Prepare the Functions Package

1. Publish the Functions project in Release configuration from its exact clean
   source revision.
2. Confirm that `host.json` is at the publish-output root.
3. Confirm that local settings are absent from the publish output.
4. Create the deployment ZIP from the publish-output contents.
5. Calculate the ZIP checksum and keep it with the ignored release output.
6. Verify that the immediately previous Functions ZIP, source revision, and
   checksum remain available as the executable rollback.

For a Function-only release, also record the unchanged immutable Render image
that was used for compatibility validation.

## Preview and Apply the Infrastructure

1. Validate the subscription-scope application template with the tracked
   development parameters and the currently selected immutable Render image.
2. Save a full Bicep What-If result outside tracked source.
3. Review every create, modify, and delete operation.
4. Stop when the preview targets an unexpected resource or includes an
   unexplained destructive change.
5. Apply only the intended infrastructure changes with the same inputs reviewed
   by What-If. A Function-only package release requires no Bicep apply when the
   preview contains no intended infrastructure change.
6. Read the Functions and Render host information from the deployment outputs
   into the local shell.

Do not replace the reviewed image input or environment parameters between the
preview and apply commands.

## Order Authentication Changes Safely

When a release changes the authentication boundaries, use this order:

1. Establish the Function system identity, Render base URL, and Render audience
   through a reviewed infrastructure preview and apply.
2. Deploy and verify Functions code that can call Render with the
   system-assigned identity.
3. Preview, review, and enable Container Apps authentication; verify
   Function-mediated success and direct unauthenticated rejection.
4. Prove that an existing Function host key can be read without output or
   persistence.
5. Deploy the Functions package whose readiness and render triggers require
   Function authorization.

Do not combine a failed step with the next mutation. Keep the previous verified
Functions ZIP available throughout the sequence.

## Publish the Functions Package

Immediately before deployment, recheck the clean source revision, exact ZIP
checksum, selected Azure context, and verified previous Functions ZIP. Publish
only the prepared ZIP to the Functions host resolved in the local shell.

Before deployment, use `Test-ExistingDefaultFunctionHostKey` from
`scripts/azure/Html2b.AzureDevValidation.psm1` for the existing-key preflight.
It returns only the key name and pass status:

```powershell
Import-Module `
    ./scripts/azure/Html2b.AzureDevValidation.psm1 `
    -Force

$keyPreflight = Test-ExistingDefaultFunctionHostKey `
    -Subscription $subscriptionId `
    -GroupName $resourceGroupName `
    -AppName $functionAppName

if ($keyPreflight.status -ne 'passed') {
    throw 'The existing Function host key preflight failed.'
}

$keyPreflight = $null
```

After deployment, use
`scripts/azure/Test-AzureDev.ps1` for the live matrix. The validator retrieves
and uses the named existing host key internally and does not emit or persist
the value. Do not reproduce the key-reading command in a transcript or pass a
key on a command line.

## Verify the Release

Run `scripts/azure/Test-AzureDev.ps1` with non-secret identifiers and the
expected immutable Render image held in the operator's session. The validator
owns Function-key retrieval and use.

Require this HTTP matrix:

1. Functions liveness without a key returns `200` and `live`.
2. Functions readiness and rendering without a key return `401` before trigger
   execution and create no Render dependency.
3. Keyed readiness returns `200` and `ready`. After scale-to-zero, an initial
   `503`/`not-ready` may converge within the bounded validation interval.
4. Keyed PNG, JPEG, and PDF requests return `200` with the documented media
   type, attachment metadata, non-empty output, signature, and dimensions.
5. Direct Render requests with no token, a malformed token, or a
   wrong-audience token return `401`.
6. If no separately authorized safe second-principal token is available,
   record the wrong-principal check as skipped rather than claiming a `403`
   result.

Also require non-secret Azure readback:

- The Function host is running with a system-assigned identity, the expected
  Render HTTPS base URL, and an audience shaped as
  `api://<render-api-client-id>`.
- Container Apps authentication is enabled, requires HTTPS, validates the
  exact audience and one Function principal, and has no excluded paths.
- The active Render revision is healthy and uses the selected immutable image,
  three container-port probes, the reviewed scale limits, and the expected
  replica count.
- No-key requests produce zero Render dependencies, while keyed readiness and
  render requests produce qualifying dependencies.
- A repeat full-payload What-If with the same inputs contains no unexplained
  material change.

Store command output and generated files only in ignored release-output
locations.

## Roll Back

For a Function-edge failure, first deploy the immediately previous verified
Functions ZIP while leaving Render authentication and the immutable Render
image unchanged. Re-run the complete authorization, health, output, telemetry,
and resource-state matrix. Inspect the predecessor package metadata before
deployment. If it restores anonymous readiness or render triggers, the rollback
temporarily reopens those public Functions routes; record and limit that
exposure until the corrected Function-authorized package is redeployed.

If Container Apps authentication itself must be disabled, create a fresh
current-state full-payload What-If that changes only the authentication
platform state and retains the current image and other settings. Review it and
obtain separate rollback approval before applying it. Disabling authentication
reopens the public Render hostname to anonymous callers; treat that as an
explicit temporary exposure and re-enable the reviewed policy after the
failure is corrected.

Use a coordinated two-host rollback only when the failed release changed both
artifacts. Select the exact verified source and immutable artifact for each
host, preview any infrastructure change, deploy in dependency order, and repeat
the full release verification.

Creating, rotating, or deleting Function keys and deleting identities, app
registrations, revisions, images, evidence, or resources are separate
operations, not rollback steps.

## Development Deployment Limits

- Both hosts use public HTTPS endpoints. Render is identity-protected but is
  not network-private.
- Render scales to zero. Chromium startup can temporarily return
  `503`/`not-ready` before readiness converges.
- Azure endpoints, retained images, Functions execution, logging, and telemetry
  can incur charges.
- The service renders server-owned HTML. It is not an isolation boundary for
  caller-authored HTML or arbitrary caller-selected network and file access.
- A Function key is a shared caller credential for the protected Functions
  routes; it is not end-user identity or browser authentication.
