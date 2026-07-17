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
    src/api/Html2b.ApiFunctions/local.settings.sample.json `
    src/api/Html2b.ApiFunctions/local.settings.json
```

In the copied `local.settings.json`, set
`RenderService__BaseUrl` to `http://localhost:8081`; the tracked sample keeps a
placeholder value.

Visual Studio 2026 can start both processes with one F5:

1. Open `src/api/Html2b.slnx`.
2. Select the shared `Html2b local` launch profile.
3. Press F5. Visual Studio starts `Html2b.Render` in its Linux Docker container
   on `127.0.0.1:8081` and starts `Html2b.ApiFunctions` on the Windows host at
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
Push-Location src/api/Html2b.ApiFunctions
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
> The immutable Feature 002 image shown below remains live and can be retained
> as a rollback target, but its single-container publication workflow does not
> support the split Feature 003 source. Do not run
> `scripts/azure/Publish-Html2bImage.ps1` from current `HEAD`, do not repoint it
> to only one of the new hosts, and do not deploy a new Feature 003 image to
> the existing single-container app. Feature 007 owns the replacement
> deployment topology and publication workflow.

The repository includes Bicep and local PowerShell helpers for the manually
operated development environment in `rg-html2b-dev` (`westus2`). The verified
environment contains exactly:

| Resource | Name |
| --- | --- |
| Azure Container Registry | `crhtml2bdev` |
| Log Analytics workspace | `log-html2b-dev` |
| Container Apps environment | `cae-html2b-dev` |
| User-assigned runtime identity | `id-html2b-api-dev` |
| Container App | `ca-html2b-dev` |

The generated endpoint is
[`https://ca-html2b-dev.ashyisland-b79aded0.westus2.azurecontainerapps.io`](https://ca-html2b-dev.ashyisland-b79aded0.westus2.azurecontainerapps.io).
It has external HTTPS ingress, no application authentication, one active
revision, 1 vCPU, 2 GiB of memory, and scales from zero to at most one replica.
The runtime identity can pull only from the `html2b-api` ACR repository. The
local deployment operator can write only to that repository; ACR admin and
anonymous access are disabled.

### Prerequisites

The verified manual workflow uses PowerShell 7, Azure CLI with Bicep, Docker
Desktop in Linux container mode, and the .NET 10 SDK. Sign in to Azure and
select the intended subscription before running a deployment command:

```powershell
az account show --query '{name:name,id:id,tenantId:tenantId,state:state}'
```

The operator needs permission to create the planned resources and role
assignments. The scripts are deliberately limited to the exact dev resource
names above. They do not create GitHub/OIDC deployment identities, registry
passwords, or remote automation.

### Deploy manually

For a first deployment, validate and preview the image-ready foundation:

```powershell
./scripts/azure/Deploy-AzureDev.ps1 -Operation Validate
./scripts/azure/Deploy-AzureDev.ps1 -Operation WhatIf
```

Inspect the exact subscription, resource group, names, tags, and repository
role conditions. After separate approval for the live foundation mutation, run:

```powershell
./scripts/azure/Deploy-AzureDev.ps1 -Operation ApplyFoundation -Confirm
```

Application mode references the existing foundation and cannot silently
converge ACR, logging, identity, or the Container Apps environment. A later
foundation change must use its own preview, explicit approval, and
`ApplyFoundation` operation. Current `HEAD` has no approved image publication
or application-apply path for this Feature 002 topology.

### Validate the live service

Run the live validator with the deployed immutable digest:

```powershell
$containerImage = 'crhtml2bdev.azurecr.io/html2b-api@sha256:c12f592d54c04011c7c83db9a22d811107877fbac69777cd3cb881dff505eeb9'
./scripts/azure/Test-AzureDev.ps1 -ExpectedContainerImage $containerImage
```

The validator checks the exact resource inventory, repository roles, runtime
pull identity, revision health, HTTPS redirect, probes, CPU/memory, replica cap,
PNG/JPEG/PDF headers and bytes, raster dimensions, PDF page size, and sanitized
logs. It then waits for zero replicas, wakes the service through readiness, and
repeats the render checks. The first verified run scaled to zero in 466.7
seconds and became Chromium-ready 26 seconds after the cold request. Evidence
is written beneath `build/validation/002/p01/live/` and is not committed.

The current verified image is:

```text
crhtml2bdev.azurecr.io/html2b-api@sha256:c12f592d54c04011c7c83db9a22d811107877fbac69777cd3cb881dff505eeb9
```

### Deploy a new image

Do not deploy a new image from current `HEAD` to the Feature 002 Container App.
Wait for Feature 007 to define and validate both deployable hosts, their
network boundary, and the replacement publication workflow. Existing ACR
artifacts remain retained and may incur charges; do not retag a digest or use
`latest` as an update or rollback mechanism.

### Roll back an image

Rollback is another reviewed immutable deployment, not a traffic edit or tag
mutation. Preview the previously recorded digest, obtain live-apply approval,
apply it as a new revision, and rerun full validation:

```powershell
$previousImage = 'crhtml2bdev.azurecr.io/html2b-api@sha256:c12f592d54c04011c7c83db9a22d811107877fbac69777cd3cb881dff505eeb9'
./scripts/azure/Deploy-AzureDev.ps1 -Operation WhatIf -ContainerImage $previousImage
./scripts/azure/Deploy-AzureDev.ps1 -Operation Apply -ContainerImage $previousImage -Confirm
./scripts/azure/Test-AzureDev.ps1 -ExpectedContainerImage $previousImage
```

The first deployment has no earlier live digest to restore. A usable rollback
point exists only after a later image update has recorded the current digest.
Do not delete failed revisions or images as part of rollback.

This environment remains manual and development-only. It has no custom domain,
authentication, persistence, backup, production SLA, multi-replica
availability, or untrusted-content sandbox. Fixed trusted HTML is the only
supported render input. The public endpoint, retained ACR artifacts, and Log
Analytics ingestion can incur Azure charges even though the app scales to zero.

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
