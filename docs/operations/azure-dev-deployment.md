# Azure Development Deployment

Html2B uses an operator-driven Azure release. Bicep provisions the application
infrastructure, Azure Container Registry builds the Render image, and the
Functions package is published from the same source revision.

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

The deployment uses existing shared registry, logging, and Container Apps
environment resources. The application templates create or update the
Functions resources, Render identity, Render application, and required
repository-scoped image access.

## Prerequisites

- PowerShell 7.
- Git.
- .NET 10 SDK.
- Azure CLI with Bicep.
- An Azure CLI session with permission to validate and apply the templates,
  build in the registry, publish the Functions package, and manage the required
  role assignments.
- A clean Git working tree at the source revision being released.

Keep subscription, tenant, operator, resource, host, and artifact values in the
operator's session or ignored release output. Do not add them to source files
or this guide.

## Validate the Repository Sources

From the repository root:

```powershell
dotnet restore src/api/Html2b.slnx
dotnet build src/api/Html2b.slnx --configuration Release --no-restore

az bicep build --file bicep/main.bicep --stdout | Out-Null
az bicep build --file bicep/bootstrap.bicep --stdout | Out-Null
az bicep build-params `
    --file bicep/environments/dev.bicepparam `
    --stdout |
    Out-Null
```

Stop if any restore, build, or Bicep compilation fails.

## Select and Verify the Azure Context

1. Sign in with Azure CLI.
2. List the available subscriptions.
3. Select the development subscription in the local shell.
4. Read the active account back from Azure CLI and verify it before continuing.
5. Resolve the signed-in operator identity only in the local shell.
6. Confirm that the shared resources referenced by the tracked environment
   parameters exist.

Do not copy values returned by these checks into documentation or tracked
files.

## Prepare the Render Image

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

1. Publish the Functions project in Release configuration from the same clean
   source revision used for Render.
2. Confirm that `host.json` is at the publish-output root.
3. Confirm that local settings are absent from the publish output.
4. Create the deployment ZIP from the publish-output contents.
5. Calculate the ZIP checksum and keep it with the ignored release output.

The Render image and Functions ZIP must come from the same source revision.

## Preview and Apply the Infrastructure

1. Validate the subscription-scope application template with the tracked
   development parameters and resolved Render image.
2. Save a full Bicep What-If result outside tracked source.
3. Review every create, modify, and delete operation.
4. Stop when the preview targets an unexpected resource or includes an
   unexplained destructive change.
5. Apply the same template inputs reviewed by What-If.
6. Read the Functions and Render host information from the deployment outputs
   into the local shell.

Do not replace the reviewed image input or environment parameters between the
preview and apply commands.

## Publish the Functions Package

Publish the prepared ZIP to the Functions host returned by the deployment.
Keep the command bound to the Azure context verified earlier in the release.

## Verify the Release

1. Read both Azure resources back and confirm successful provisioning.
2. Confirm that the deployed Render revision uses the immutable image selected
   during preview.
3. Call the Render liveness and readiness endpoints using the deployment
   output retained in the local shell.
4. Call the Functions liveness and readiness endpoints using its deployment
   output.
5. Request a PNG through the Functions render endpoint.
6. Confirm status `200`, content type `image/png`, a non-empty body, and the PNG
   file signature.
7. Repeat Bicep What-If with the same inputs and inspect any reported
   provider-derived property differences.

Store command output and generated files only in ignored release-output
locations.

## Roll Back

1. Select the exact source revision for the previously deployed matching
   release.
2. Rebuild the Render image and Functions package from a clean archive of that
   revision.
3. Resolve the rebuilt image to an immutable digest and calculate the Functions
   ZIP checksum.
4. Run and review Bicep What-If with the rollback image.
5. Apply the reviewed infrastructure inputs.
6. Publish the matching Functions ZIP.
7. Repeat every resource, health, render, and convergence check from the release
   verification section.

Do not roll back one host without rebuilding and selecting the matching
artifact for the other host.
