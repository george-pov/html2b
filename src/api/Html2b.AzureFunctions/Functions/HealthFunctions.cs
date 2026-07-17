using Html2b.Application.Rendering;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace Html2b.AzureFunctions.Functions;

public sealed class HealthFunctions(IRenderReadinessProbe readinessProbe)
{
    [Function("HealthLive")]
    public IActionResult Live(
        [HttpTrigger(
            AuthorizationLevel.Anonymous,
            "get",
            Route = "health/live")]
        HttpRequest request)
    {
        return new OkObjectResult(new { status = "live" });
    }

    [Function("HealthReady")]
    public async Task<IActionResult> ReadyAsync(
        [HttpTrigger(
            AuthorizationLevel.Anonymous,
            "get",
            Route = "health/ready")]
        HttpRequest request,
        CancellationToken cancellationToken)
    {
        var isReady = await readinessProbe.IsReadyAsync(cancellationToken);

        return new ObjectResult(
            new { status = isReady ? "ready" : "not-ready" })
        {
            StatusCode = isReady
                ? StatusCodes.Status200OK
                : StatusCodes.Status503ServiceUnavailable,
        };
    }
}
