using Html2b.WebApi.Rendering;

using Microsoft.AspNetCore.Mvc;

namespace Html2b.WebApi.Controllers;

[ApiController]
[Route("api/renders")]
public sealed class RendersController(ChromiumRenderer renderer) : ControllerBase
{
    private const string PocHtml = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Html2B rendering POC</title>
          <style>
            *, *::before, *::after { box-sizing: border-box; }
            html, body { margin: 0; width: 1280px; height: 720px; overflow: hidden; }
            body {
              display: grid;
              place-items: center;
              background: #14213d;
              color: #fca311;
              font: 700 64px/1.1 Arial, sans-serif;
              -webkit-print-color-adjust: exact;
              print-color-adjust: exact;
            }
            main { width: 1280px; text-align: center; }
          </style>
        </head>
        <body>
          <main>Hello from Html2B</main>
        </body>
        </html>
        """;

    [HttpPost("{format}")]
    public async Task<IActionResult> PostAsync(
        string format,
        CancellationToken cancellationToken)
    {
        if (!TryParseFormat(format, out var renderFormat))
        {
            return Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Unsupported output format",
                detail: "Supported formats: png, jpeg, pdf.");
        }

        var bytes = await renderer.RenderAsync(
            PocHtml,
            renderFormat,
            cancellationToken);
        var responseMetadata = GetResponseMetadata(renderFormat);

        return File(
            bytes,
            responseMetadata.ContentType,
            responseMetadata.FileName);
    }

    private static bool TryParseFormat(string value, out RenderFormat format)
    {
        if (string.Equals(value, "png", StringComparison.OrdinalIgnoreCase))
        {
            format = RenderFormat.Png;
            return true;
        }

        if (string.Equals(value, "jpeg", StringComparison.OrdinalIgnoreCase))
        {
            format = RenderFormat.Jpeg;
            return true;
        }

        if (string.Equals(value, "pdf", StringComparison.OrdinalIgnoreCase))
        {
            format = RenderFormat.Pdf;
            return true;
        }

        format = default;
        return false;
    }

    private static (string ContentType, string FileName) GetResponseMetadata(
        RenderFormat format)
    {
        return format switch
        {
            RenderFormat.Png => ("image/png", "html2b-poc.png"),
            RenderFormat.Jpeg => ("image/jpeg", "html2b-poc.jpg"),
            RenderFormat.Pdf => ("application/pdf", "html2b-poc.pdf"),
            _ => throw new ArgumentOutOfRangeException(nameof(format)),
        };
    }
}
