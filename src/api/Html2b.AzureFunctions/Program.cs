using Html2b.Infrastructure;

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();
builder.Services
    .AddApplicationInsightsTelemetryWorkerService(options =>
    {
        options.EnableAdaptiveSampling = false;
    })
    .ConfigureFunctionsApplicationInsights();
builder.Services.AddInfrastructure(builder.Configuration);

builder.Build().Run();
