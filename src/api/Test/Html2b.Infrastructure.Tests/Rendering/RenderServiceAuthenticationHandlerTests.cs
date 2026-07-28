using System.Net;
using System.Net.Http.Headers;

using Azure.Core;
using Azure.Identity;

using Html2b.Infrastructure.Rendering;
using Html2b.Infrastructure.Tests.TestDoubles;

using Microsoft.Extensions.Options;

namespace Html2b.Infrastructure.Tests.Rendering;

public sealed class RenderServiceAuthenticationHandlerTests
{
    private const string Audience =
        "api://11111111-1111-1111-1111-111111111111";
    private const string Scope =
        "api://11111111-1111-1111-1111-111111111111/.default";
    private const string RemoteBaseUrl =
        "https://render.example.test";

    [Fact]
    public async Task RenderAndReadiness_RequestExactDefaultScope()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);

        using var renderResponse = await client.PostAsync(
            "/internal/renders",
            new StringContent("{}"));
        using var readinessResponse = await client.GetAsync("/health/ready");

        Assert.Equal(2, credential.RequestCount);
        Assert.All(
            credential.RequestedScopes,
            scopes => Assert.Equal([Scope], scopes));
        Assert.Equal(2, transport.Requests.Count);
    }

    [Fact]
    public async Task RemoteHttps_AddsManagedIdentityBearerToken()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);

        using var response = await client.GetAsync("/health/ready");

        var request = Assert.Single(transport.Requests);
        Assert.Equal("Bearer", request.AuthorizationScheme);
        Assert.Equal("test-token", request.AuthorizationParameter);
    }

    [Fact]
    public async Task LoopbackHttp_SendsWithoutTokenOrAuthorization()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = CreateClient(
            credential,
            transport,
            "http://localhost:8081",
            string.Empty);

        using var response = await client.GetAsync("/health/ready");

        Assert.Equal(0, credential.RequestCount);
        var request = Assert.Single(transport.Requests);
        Assert.Null(request.AuthorizationScheme);
        Assert.Null(request.AuthorizationParameter);
    }

    [Fact]
    public async Task LoopbackHttpWithPreexistingBearer_FailsBeforeTransport()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        using var client = CreateClient(
            credential,
            transport,
            "http://localhost:8081",
            string.Empty);
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            "/health/ready");
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", "caller-token");

        await Assert.ThrowsAsync<HttpRequestException>(
            () => client.SendAsync(request));

        Assert.Equal(0, credential.RequestCount);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task NonLoopbackHttp_FailsBeforeTokenOrTransport()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        using var client = CreateClient(
            credential,
            transport,
            "http://render.example.test",
            Audience);

        await Assert.ThrowsAsync<HttpRequestException>(
            () => client.GetAsync("/health/ready"));

        Assert.Equal(0, credential.RequestCount);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData("https://other.example.test/health/ready")]
    [InlineData("https://render.example.test:444/health/ready")]
    [InlineData("http://render.example.test/health/ready")]
    public async Task CrossOriginAbsoluteRequest_FailsBeforeTokenOrTransport(
        string requestUri)
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);

        await Assert.ThrowsAsync<HttpRequestException>(
            () => client.GetAsync(requestUri));

        Assert.Equal(0, credential.RequestCount);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task MalformedAudience_FailsBeforeTokenOrTransport()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            $"{Audience}/.default");

        await Assert.ThrowsAsync<HttpRequestException>(
            () => client.GetAsync("/health/ready"));

        Assert.Equal(0, credential.RequestCount);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task RemoteHttps_ReplacesPreexistingAuthorization()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            "/health/ready");
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", "caller-token");

        using var response = await client.SendAsync(request);

        var recordedRequest = Assert.Single(transport.Requests);
        Assert.Equal("Bearer", recordedRequest.AuthorizationScheme);
        Assert.Equal(
            "test-token",
            recordedRequest.AuthorizationParameter);
    }

    [Fact]
    public async Task RedirectResponse_IsReturnedWithoutReplay()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        var redirectResponse =
            new HttpResponseMessage(HttpStatusCode.TemporaryRedirect);
        redirectResponse.Headers.Location =
            new Uri("https://other.example.test/health/ready");
        transport.EnqueueResponse(redirectResponse);
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);

        using var response = await client.GetAsync("/health/ready");

        Assert.Equal(
            HttpStatusCode.TemporaryRedirect,
            response.StatusCode);
        Assert.Single(transport.Requests);
        Assert.Equal(1, credential.RequestCount);
    }

    [Fact]
    public async Task MultipleRequests_ReuseTheSameCredential()
    {
        var credential = new FakeTokenCredential();
        var transport = new RecordingHttpMessageHandler();
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        transport.EnqueueResponse(new HttpResponseMessage(HttpStatusCode.OK));
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);

        using var firstResponse = await client.GetAsync("/health/ready");
        using var secondResponse = await client.GetAsync("/health/ready");

        Assert.Equal(2, credential.RequestCount);
        Assert.All(
            credential.RequestedScopes,
            scopes => Assert.Equal([Scope], scopes));
    }

    [Fact]
    public async Task CredentialFailure_BecomesSanitizedHttpRequestException()
    {
        const string providerDetail = "fake-provider-detail";
        const string tokenDetail = "fake-provider-test-token";
        var credential = new FakeTokenCredential
        {
            ExceptionToThrow = new AuthenticationFailedException(
                $"{providerDetail} {tokenDetail}"),
        };
        var transport = new RecordingHttpMessageHandler();
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);

        var exception = await Assert.ThrowsAsync<HttpRequestException>(
            () => client.GetAsync("/health/ready"));

        Assert.DoesNotContain(
            providerDetail,
            exception.Message,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            tokenDetail,
            exception.Message,
            StringComparison.Ordinal);
        Assert.Null(exception.InnerException);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task CallerCancellation_RemainsOperationCanceledException()
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
        var transport = new RecordingHttpMessageHandler();
        using var client = CreateClient(
            credential,
            transport,
            RemoteBaseUrl,
            Audience);
        using var cancellationSource = new CancellationTokenSource();

        var request = client.GetAsync(
            "/health/ready",
            cancellationSource.Token);
        await tokenRequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellationSource.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => request);
        Assert.Empty(transport.Requests);
    }

    private static HttpClient CreateClient(
        FakeTokenCredential credential,
        RecordingHttpMessageHandler transport,
        string baseUrl,
        string audience)
    {
        var handler = new RenderServiceAuthenticationHandler(
            credential,
            Options.Create(
                new RenderServiceOptions
                {
                    BaseUrl = baseUrl,
                    Audience = audience,
                }))
        {
            InnerHandler = transport,
        };

        return new HttpClient(handler)
        {
            BaseAddress = new Uri(baseUrl),
        };
    }
}
