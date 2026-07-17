using Html2b.Application.Rendering;
using Html2b.Contracts.Rendering;
using Html2b.Domain.Rendering;
using Html2b.Render.Rendering;

namespace Html2b.Render.Endpoints;

public static class RenderEndpoints
{
    public static IEndpointRouteBuilder MapRenderEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapPost(
            "/internal/renders",
            RenderAsync);

        return endpoints;
    }

    private static async Task<IResult> RenderAsync(
        PocRenderRequestV1 request,
        IRenderEngine renderEngine,
        CancellationToken cancellationToken)
    {
        if (!RenderFormat.TryParse(request.Format, out var format))
        {
            return Results.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                title: "Unsupported render format");
        }

        try
        {
            var renderedFile = await renderEngine.RenderAsync(
                PocHtmlTemplate.Html,
                format,
                cancellationToken);

            return Results.File(
                renderedFile.Content,
                renderedFile.ContentType,
                renderedFile.FileName);
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Rendering failed");
        }
    }
}
