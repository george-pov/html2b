using Html2b.Render.Rendering;

namespace Html2b.Render.Endpoints;

public static class HealthEndpoints
{
    public static IEndpointRouteBuilder MapHealthEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapGet(
            "/health/live",
            () => Results.Ok(new { status = "live" }));
        endpoints.MapGet(
            "/health/ready",
            (ChromiumRenderer renderer) =>
            {
                var isReady = renderer.IsReady;
                return Results.Json(
                    new { status = isReady ? "ready" : "not-ready" },
                    statusCode: isReady
                        ? StatusCodes.Status200OK
                        : StatusCodes.Status503ServiceUnavailable);
            });

        return endpoints;
    }
}
