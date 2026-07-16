# Html2B

Html2B is an online service for generating thumbnails and other static images from reusable HTML and CSS templates.

Users create one or more templates using regular HTML, inline CSS, and replaceable tokens such as `{{ title }}`. A template can define text fields, reference uploaded images and other assets, and render them as a static web page. Html2B captures that page at a requested size and exports the result as PNG, JPEG, PDF, or another supported format.

The primary use case is generating thumbnail images for YouTube streams, but the same approach can support social media graphics, banners, reports, certificates, and other consistently rendered content.

> [!NOTE]
> Html2B is currently an early-stage project. The API and implementation details described below are the intended direction and may change as the project develops.

## Containerized rendering POC

The repository includes a local proof of concept under `src/api` that runs one
ASP.NET Core API and one Playwright-managed Chromium browser in the same Linux
container. The POC renders one trusted, server-owned HTML document at 1280 by
720 and returns PNG, JPEG, or PDF bytes without persisting output.

### Windows prerequisites

The verified Windows setup uses:

- WSL 2.1.5 or later.
- Docker Desktop with the WSL 2 backend and Linux container mode.
- Docker Compose v2.
- The .NET 10 SDK.

Verify an existing workstation from PowerShell:

```powershell
wsl --version
wsl --list --verbose
dotnet --list-sdks
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

From the repository root, build and start the service:

```powershell
docker compose up --build
```

The API listens over HTTP at `http://localhost:8080`. In another terminal,
check process liveness and browser readiness:

```powershell
Invoke-WebRequest http://localhost:8080/health/live
Invoke-WebRequest http://localhost:8080/health/ready
```

Stop the service and its local Compose network with:

```powershell
docker compose down
```

The image runs the API as the non-root `pwuser` under `tini`, includes a Docker
liveness health check, and gives the hosted browser up to 30 seconds to shut
down cleanly.

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
`pdf` as the supported values. The process reuses one hosted browser, permits
one active render at a time, and creates a fresh restricted browser context and
page for every request.

### POC limitations

- HTML, text, dimensions, JPEG quality, and PDF settings are hardcoded. The POC
  does not accept templates, tokens, caller HTML, uploads, URLs, or assets.
- JavaScript, service workers, downloads, and HTTP or HTTPS page requests are
  blocked. Output remains in memory and is not persisted.
- The approved POC has no automated test project; its API, output, browser, and
  container lifecycle were validated manually.
- The Playwright container launches Chromium with `--no-sandbox`. Combined
  with the lack of authentication, resource limits, and production isolation,
  this makes the image unsuitable as a sandbox for untrusted HTML.
- Azure deployment is not implemented. This repository does not install or use
  Azure CLI, publish an image to a registry, create Container Apps resources,
  configure ingress, probes, identity, secrets, or scaling, or validate a live
  Azure endpoint. Those are future deployment and production-hardening tasks.

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
