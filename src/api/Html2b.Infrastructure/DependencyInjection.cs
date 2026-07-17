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
        services
            .AddOptions<RenderServiceOptions>()
            .Bind(configuration.GetSection(RenderServiceOptions.SectionName))
            .Validate(
                options => TryGetValidBaseUri(options.BaseUrl, out _),
                $"{RenderServiceOptions.SectionName}:BaseUrl must be an absolute HTTP URI.")
            .ValidateOnStart();

        services.AddHttpClient<PocRenderHttpClient>(
            (provider, client) =>
            {
                var options = provider
                    .GetRequiredService<IOptions<RenderServiceOptions>>()
                    .Value;

                _ = TryGetValidBaseUri(options.BaseUrl, out var baseUri);
                client.BaseAddress = baseUri;
                client.Timeout = Timeout.InfiniteTimeSpan;
            });

        services.AddTransient<IPocRenderGateway>(
            provider => provider.GetRequiredService<PocRenderHttpClient>());
        services.AddTransient<IRenderReadinessProbe>(
            provider => provider.GetRequiredService<PocRenderHttpClient>());

        return services;
    }

    private static bool TryGetValidBaseUri(string value, out Uri? uri)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out uri) &&
            string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        uri = null;
        return false;
    }
}
