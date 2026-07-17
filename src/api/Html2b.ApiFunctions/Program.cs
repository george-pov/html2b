using Html2b.Infrastructure;

using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();
builder.Services.AddInfrastructure(builder.Configuration);

builder.Build().Run();
