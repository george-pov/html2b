# Html2B

Html2B is an online service for generating thumbnails and other static images from reusable HTML and CSS templates.

Users create one or more templates using regular HTML, inline CSS, and replaceable tokens such as `{{ title }}`. A template can define text fields, reference uploaded images and other assets, and render them as a static web page. Html2B captures that page at a requested size and exports the result as PNG, JPEG, PDF, or another supported format.

The primary use case is generating thumbnail images for YouTube streams, but the same approach can support social media graphics, banners, reports, certificates, and other consistently rendered content.

> [!NOTE]
> Html2B is currently an early-stage project. The API and implementation details described below are the intended direction and may change as the project develops.

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

## Development

The repository is currently a scaffold and does not yet contain a solution or runnable projects. Once the initial .NET solution is added, the expected commands are:

```powershell
dotnet restore
dotnet build --configuration Release
dotnet test --configuration Release
dotnet run --project src/Html2B.WebApi
```

## Security considerations

Rendering user-authored HTML is a security-sensitive operation. The service will need strict isolation, resource and execution limits, controlled network access, input validation, and safe asset handling before it can accept untrusted templates.

## License

No license has been selected yet.
