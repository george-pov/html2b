using Html2b.Application.Rendering;
using Html2b.Domain.Rendering;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace Html2b.ApiFunctions.Functions;

public sealed class RendersFunction(IPocRenderGateway renderGateway)
{
    [Function("RenderPoc")]
    public async Task<IActionResult> PostAsync(
        [HttpTrigger(
            AuthorizationLevel.Anonymous,
            "post",
            Route = "api/renders/{format}")]
        HttpRequest request,
        string format,
        CancellationToken cancellationToken)
    {
        if (!RenderFormat.TryParse(format, out var renderFormat))
        {
            return new BadRequestObjectResult(
                new ProblemDetails
                {
                    Status = StatusCodes.Status400BadRequest,
                    Title = "Unsupported output format",
                    Detail = $"Supported formats: {string.Join(", ", RenderFormat.SupportedValues)}.",
                });
        }

        try
        {
            var renderedFile = await renderGateway.RenderAsync(
                renderFormat,
                cancellationToken);

            return new FileContentResult(
                renderedFile.Content,
                renderedFile.ContentType)
            {
                FileDownloadName = renderedFile.FileName,
            };
        }
        catch (RenderGatewayException)
        {
            return new ObjectResult(
                new ProblemDetails
                {
                    Status = StatusCodes.Status503ServiceUnavailable,
                    Title = "Render service unavailable",
                })
            {
                StatusCode = StatusCodes.Status503ServiceUnavailable,
            };
        }
    }
}
