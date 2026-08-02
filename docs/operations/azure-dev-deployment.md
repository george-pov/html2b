# Azure Development Deployment

Html2B uses an operator-driven Azure release. Bicep provisions the application
infrastructure, Azure Container Registry builds the Render image, and the
Functions package is deployed separately. Each changed artifact is produced
from clean source and recorded with its immutable identity. A Function-only
release retains the deployed immutable Render image; a release
that changes both hosts builds both artifacts from the same clean revision.

This guide intentionally contains no environment-specific identifiers,
resource names, hostnames, release hashes, artifact digests, or deployment
outputs. Resolve those values from the selected Azure context, tracked
environment parameters, and command output during the release.

## Repository Sources

- `bicep/main.bicep` composes the application infrastructure.
- `bicep/environments/dev.bicepparam` contains tracked development parameters.
  It reads the release-specific immutable Render image from the operator's
  `HTML2B_CONTAINER_IMAGE` environment variable.
- `bicep/modules/` contains the Functions and Render resource definitions.
- `src/api/Html2b.Render/Dockerfile` builds the Render image.
- `src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj` builds the
  Functions package.

The deployment uses existing shared registry, logging, and Container Apps
environment resources. The application templates create or update the
Functions resources and system identity, Render user-assigned image-pull
identity and Container App, Container Apps authentication, and required
repository-scoped image access.
The tracked environment parameters supply the non-secret Render API client ID;
the Microsoft Entra app registration and service principal already exist.

## Prerequisites

- PowerShell 7.3 or later.
- Git.
- .NET 10 SDK.
- Azure CLI with Bicep.
- An Azure CLI session with permission to validate and apply the templates,
  build in the registry, publish the Functions package, and manage the Render
  image-pull role assignment.
- Existing repository-scoped registry Writer access for the signed-in operator.
- A clean Git working tree at the source revision being released.

Keep subscription, tenant, operator, resource, host, and artifact values in the
operator's session or ignored release output. Do not add them to source files
or this guide.

## Validate the Repository Sources

From the repository root:

```powershell
dotnet restore src/api/Html2b.slnx
dotnet build src/api/Html2b.slnx --configuration Release --no-restore
dotnet test src/api/Html2b.slnx --configuration Release --no-build
dotnet format src/api/Html2b.slnx --verify-no-changes --no-restore

az bicep build --file bicep/main.bicep --stdout | Out-Null
```

Stop if restore, build, tests, formatting, or Bicep compilation fails. Compile
the environment parameters after selecting the immutable Render image.

## Select and Verify the Azure Context

1. Sign in with Azure CLI.
2. List the available subscriptions.
3. Select the development subscription in the local shell.
4. Read the active account back from Azure CLI and verify it before continuing.
5. Confirm that the shared resources referenced by the tracked environment
   parameters exist.
6. Read the Render API client ID from the selected tracked environment
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

- For a Function-only change, supply the known currently deployed immutable
  Render image digest and build only the Functions ZIP from its exact clean
  source.
- When Render changes, build a new immutable Render image. When both hosts
  change together, build the image and Functions ZIP from the same clean
  revision.

Record the selected image digest, Functions source revision, ZIP checksum, and
their verified compatibility in ignored release output.

Set `HTML2B_CONTAINER_IMAGE` in the operator's session to the complete
digest-qualified image reference, then compile the environment parameters:

```powershell
az bicep build-params `
    --file bicep/environments/dev.bicepparam `
    --stdout |
    Out-Null
```

Stop if parameter compilation fails.

## Prepare the Render Image

Perform these steps only when the release changes Render:

1. Create a clean source archive from the exact Git revision being released.
2. Build the Render Dockerfile through Azure Container Registry using that
   clean archive as the build context.
3. Tag the build with the full source revision.
4. Resolve the resulting immutable manifest digest from the registry.
5. Keep the source revision and resolved digest together in ignored release
   output.

Repository-scoped registry Writer access is an operator prerequisite. The
application templates do not grant or migrate deployment-operator access.

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

Do not replace the reviewed image input or environment parameters between the
preview and apply commands.

## Publish the Functions Package

Immediately before deployment, recheck the clean source revision, exact ZIP
checksum, selected Azure context, and verified previous Functions ZIP. Publish
only the prepared ZIP to the Functions host resolved in the local shell.

The infrastructure workflow completes after Azure accepts the Bicep Apply. It
requires an explicit digest-qualified Render image for every run, performs a
What-If that blocks Apply when it includes a deletion, and does not make
post-Apply Azure resource readback checks. Application deployment completes
after Azure accepts the Render revision update and Functions package
deployment. It does not make post-deployment HTTP requests, retrieve Function
keys, wait for cold starts, query telemetry, or assert live Azure resource
state.

## Roll Back

For a Function-edge failure, first deploy the immediately previous verified
Functions ZIP while leaving Render authentication and the immutable Render
image unchanged. Inspect the predecessor package metadata before deployment.
If it restores anonymous readiness or render triggers, the rollback temporarily
reopens those public Functions routes; record and limit that exposure until the
corrected Function-authorized package is redeployed.

The application templates keep Container Apps authentication enabled and do
not provide an authentication-disable rollback mode. Any emergency change that
reopens direct anonymous Render access is outside the repository deployment
shape and requires separate review and authorization.

Use a coordinated two-host rollback only when the failed release changed both
artifacts. Select the exact verified source and immutable artifact for each
host, preview any infrastructure change, and deploy in dependency order.

Creating, rotating, or deleting Function keys and deleting identities, app
registrations, revisions, images, or resources are separate operations, not
rollback steps.

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
