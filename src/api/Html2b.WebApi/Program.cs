using Html2b.WebApi.Rendering;

namespace Html2b.WebApi
{
    public class Program
    {
        public static void Main(string[] args)
        {
            var builder = WebApplication.CreateBuilder(args);

            builder.Services.AddControllers();
            builder.Services.AddSingleton<ChromiumRenderer>();
            builder.Services.AddHostedService(
                provider => provider.GetRequiredService<ChromiumRenderer>());

            var app = builder.Build();

            app.MapGet(
                "/health/live",
                () => Results.Ok(new { status = "live" }));
            app.MapGet(
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
            app.MapControllers();

            app.Run();
        }
    }
}
