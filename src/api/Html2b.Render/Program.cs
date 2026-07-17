using Html2b.Application.Rendering;
using Html2b.Render.Endpoints;
using Html2b.Render.Rendering;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<ChromiumRenderer>();
builder.Services.AddSingleton<IRenderEngine>(
    provider => provider.GetRequiredService<ChromiumRenderer>());
builder.Services.AddHostedService(
    provider => provider.GetRequiredService<ChromiumRenderer>());

var app = builder.Build();

app.MapHealthEndpoints();
app.MapRenderEndpoints();

app.Run();
