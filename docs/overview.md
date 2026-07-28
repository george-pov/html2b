# Html2B Overview

Html2B renders one server-owned HTML document through Playwright and Chromium.
The service returns the rendered bytes directly to the caller.

## Capabilities

- Render the built-in document as PNG, JPEG, or PDF.
- Select the output format through the request route.
- Reuse one hosted Chromium process for rendering.
- Process one render at a time in each Render host instance.
- Report process liveness and end-to-end rendering readiness.
- Run the Functions host and Render host as separate .NET 10 processes.
- Run Render in its Linux container locally and in Azure.

## Request and Output Behavior

The Functions host receives a render request, validates the requested format,
and calls the Render host over HTTP. Render loads its built-in HTML, creates an
isolated browser context and page, captures the requested output, and returns
the file bytes. The Functions host relays those bytes to the caller.

Render requests do not accept HTML, templates, tokens, dimensions, quality
settings, URLs, uploads, or assets. Rendered files remain in memory and are not
persisted by the service.

## Documentation

- [API architecture](api/architecture.md)
- [HTTP API](api/http-api.md)
- [Local development](development/local-development.md)
- [Azure development deployment](operations/azure-dev-deployment.md)
