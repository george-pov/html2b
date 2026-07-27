using System.Net;

using Azure.Core;
using Azure.Identity;

using Html2b.Application.Rendering;
using Html2b.Domain.Rendering;
using Html2b.Infrastructure.Rendering;
using Html2b.Infrastructure.Tests.TestDoubles;

using Microsoft.Extensions.Options;

namespace Html2b.Infrastructure.Tests.Rendering;

public sealed class PocRenderHttpClientTests
{
    private const string Audience =
        "api://11111111-1111-1111-1111-111111111111";
    private const string RemoteBaseUrl =
        "https://render.example.test";

    [Fact]
    public async Task RenderAsync_CredentialFailure_ThrowsGatewayException()
    {
        var credential = CreateFailingCredential();
        var transport = new RecordingHttpMessageHandler();
        using var httpClient = CreateHttpClient(credential, transport);
        var gateway = new PocRenderHttpClient(httpClient);

        var exception = await Assert.ThrowsAsync<RenderGatewayException>(
            () => gateway.RenderAsync(
                RenderFormat.Png,
                CancellationToken.None));

        Assert.Equal(
            "The render service request failed.",
            exception.Message);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task IsReadyAsync_CredentialFailure_ReturnsFalse()
    {
        var credential = CreateFailingCredential();
        var transport = new RecordingHttpMessageHandler();
        using var httpClient = CreateHttpClient(credential, transport);
        var gateway = new PocRenderHttpClient(httpClient);

        var isReady = await gateway.IsReadyAsync(CancellationToken.None);

        Assert.False(isReady);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task RenderAsync_ProtectedRenderFailure_ThrowsGatewayException(
        HttpStatusCode statusCode)
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(statusCode));
        using var httpClient = CreateHttpClient(credential, transport);
        var gateway = new PocRenderHttpClient(httpClient);

        var exception = await Assert.ThrowsAsync<RenderGatewayException>(
            () => gateway.RenderAsync(
                RenderFormat.Png,
                CancellationToken.None));

        Assert.Equal(
            "The render service returned an unsuccessful response.",
            exception.Message);
        Assert.Single(transport.Requests);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task IsReadyAsync_ProtectedRenderFailure_ReturnsFalse(
        HttpStatusCode statusCode)
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(statusCode));
        using var httpClient = CreateHttpClient(credential, transport);
        var gateway = new PocRenderHttpClient(httpClient);

        var isReady = await gateway.IsReadyAsync(CancellationToken.None);

        Assert.False(isReady);
        Assert.Single(transport.Requests);
    }

    [Fact]
    public async Task RenderAsync_CallerCancellation_Propagates()
    {
        var (credential, tokenRequestStarted) =
            CreateBlockingCredential();
        var transport = new RecordingHttpMessageHandler();
        using var httpClient = CreateHttpClient(credential, transport);
        var gateway = new PocRenderHttpClient(httpClient);
        using var cancellationSource = new CancellationTokenSource();

        var render = gateway.RenderAsync(
            RenderFormat.Png,
            cancellationSource.Token);
        await tokenRequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellationSource.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => render);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task IsReadyAsync_CallerCancellation_Propagates()
    {
        var (credential, tokenRequestStarted) =
            CreateBlockingCredential();
        var transport = new RecordingHttpMessageHandler();
        using var httpClient = CreateHttpClient(credential, transport);
        var gateway = new PocRenderHttpClient(httpClient);
        using var cancellationSource = new CancellationTokenSource();

        var readiness = gateway.IsReadyAsync(cancellationSource.Token);
        await tokenRequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellationSource.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => readiness);
        Assert.Empty(transport.Requests);
    }

    private static FakeTokenCredential CreateFailingCredential()
    {
        return new FakeTokenCredential
        {
            ExceptionToThrow = new AuthenticationFailedException(
                "fake-provider-detail fake-provider-test-token"),
        };
    }

    private static (
        FakeTokenCredential Credential,
        TaskCompletionSource TokenRequestStarted)
        CreateBlockingCredential()
    {
        var tokenRequestStarted =
            new TaskCompletionSource(
                TaskCreationOptions.RunContinuationsAsynchronously);
        var credential = new FakeTokenCredential
        {
            Responder = async (_, cancellationToken) =>
            {
                tokenRequestStarted.SetResult();
                await Task.Delay(
                    Timeout.InfiniteTimeSpan,
                    cancellationToken);
                return new AccessToken(
                    "unreachable-test-token",
                    DateTimeOffset.UtcNow.AddHours(1));
            },
        };

        return (credential, tokenRequestStarted);
    }

    private static HttpClient CreateHttpClient(
        FakeTokenCredential credential,
        RecordingHttpMessageHandler transport)
    {
        var handler = new RenderServiceAuthenticationHandler(
            credential,
            Options.Create(
                new RenderServiceOptions
                {
                    BaseUrl = RemoteBaseUrl,
                    Audience = Audience,
                }))
        {
            InnerHandler = transport,
        };

        return new HttpClient(handler)
        {
            BaseAddress = new Uri(RemoteBaseUrl),
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }
}
