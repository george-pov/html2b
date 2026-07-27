using Azure.Core;
using Azure.Identity;

using Html2b.Infrastructure.Rendering;

using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Html2b.Infrastructure.Tests;

public sealed class DependencyInjectionTests
{
    [Fact]
    public void AddInfrastructure_RenderClientDisablesAutomaticRedirects()
    {
        using var provider = CreateServiceProvider();
        var handlerFactory =
            provider.GetRequiredService<IHttpMessageHandlerFactory>();

        var handler = handlerFactory.CreateHandler(
            nameof(PocRenderHttpClient));

        while (handler is DelegatingHandler delegatingHandler)
        {
            handler = delegatingHandler.InnerHandler ??
                throw new InvalidOperationException(
                    "The handler pipeline is incomplete.");
        }

        var socketsHandler = Assert.IsType<SocketsHttpHandler>(handler);
        Assert.False(socketsHandler.AllowAutoRedirect);
    }

    [Fact]
    public void AddInfrastructure_RegistersOneReusedSystemCredential()
    {
        using var provider = CreateServiceProvider();

        var first = provider.GetRequiredService<TokenCredential>();
        var second = provider.GetRequiredService<TokenCredential>();

        Assert.Same(first, second);
        Assert.IsType<ManagedIdentityCredential>(first);
        Assert.Single(provider.GetServices<TokenCredential>());
    }

    private static ServiceProvider CreateServiceProvider()
    {
        var configuration = new ConfigurationManager
        {
            [$"{RenderServiceOptions.SectionName}:BaseUrl"] =
                "http://localhost:8081",
        };
        var services = new ServiceCollection();
        services.AddInfrastructure(configuration);

        return services.BuildServiceProvider(
            new ServiceProviderOptions
            {
                ValidateOnBuild = true,
                ValidateScopes = true,
            });
    }
}
