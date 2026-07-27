using Azure.Core;
using Azure.Identity;

using Html2b.Application.Rendering;
using Html2b.Infrastructure.Rendering;

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Html2b.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddSingleton<
            IValidateOptions<RenderServiceOptions>,
            RenderServiceOptionsValidator>();

        services
            .AddOptions<RenderServiceOptions>()
            .Bind(configuration.GetSection(RenderServiceOptions.SectionName))
            .ValidateOnStart();

        services.AddSingleton<TokenCredential>(
            new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned));
        services.AddTransient<RenderServiceAuthenticationHandler>();

        services.AddHttpClient<PocRenderHttpClient>(
            (provider, client) =>
            {
                var options = provider
                    .GetRequiredService<IOptions<RenderServiceOptions>>()
                    .Value;

                _ = RenderServiceOptionsValidator.TryGetBaseUri(
                    options.BaseUrl,
                    out var baseUri);
                client.BaseAddress = baseUri;
                client.Timeout = Timeout.InfiniteTimeSpan;
            })
            .ConfigurePrimaryHttpMessageHandler(
                () => new SocketsHttpHandler
                {
                    AllowAutoRedirect = false,
                })
            .AddHttpMessageHandler<RenderServiceAuthenticationHandler>();

        services.AddTransient<IPocRenderGateway>(
            provider => provider.GetRequiredService<PocRenderHttpClient>());
        services.AddTransient<IRenderReadinessProbe>(
            provider => provider.GetRequiredService<PocRenderHttpClient>());

        return services;
    }
}
