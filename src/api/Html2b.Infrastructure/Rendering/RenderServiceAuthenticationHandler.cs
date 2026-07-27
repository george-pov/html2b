using System.Net.Http.Headers;

using Azure.Core;
using Azure.Identity;

using Microsoft.Extensions.Options;

namespace Html2b.Infrastructure.Rendering;

public sealed class RenderServiceAuthenticationHandler(
    TokenCredential credential,
    IOptions<RenderServiceOptions> options) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        var configuration = options.Value;

        if (!RenderServiceOptionsValidator.TryGetBaseUri(
                configuration.BaseUrl,
                out var baseUri))
        {
            throw new HttpRequestException(
                "The render service base URL is invalid.");
        }

        if (!TryGetAbsoluteRequestUri(baseUri, request.RequestUri, out var requestUri) ||
            !IsExpectedOrigin(baseUri, requestUri))
        {
            throw new HttpRequestException(
                "The render service request origin does not match its configured origin.");
        }

        request.RequestUri = requestUri;

        if (IsLoopbackHttp(baseUri))
        {
            if (!string.IsNullOrEmpty(configuration.Audience))
            {
                throw new HttpRequestException(
                    "The render service loopback configuration is invalid.");
            }

            if (request.Headers.Contains("Authorization"))
            {
                throw new HttpRequestException(
                    "Authorization is not allowed for a loopback HTTP render request.");
            }

            return await base.SendAsync(request, cancellationToken);
        }

        if (!string.Equals(
                baseUri.Scheme,
                Uri.UriSchemeHttps,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new HttpRequestException(
                "The render service request cannot use non-loopback HTTP.");
        }

        if (!RenderServiceOptionsValidator.TryGetAudienceClientId(
                configuration.Audience,
                out _))
        {
            throw new HttpRequestException(
                "The render service audience is invalid.");
        }

        AccessToken token;

        try
        {
            token = await credential.GetTokenAsync(
                new TokenRequestContext(
                    [$"{configuration.Audience}/.default"]),
                cancellationToken);
        }
        catch (AuthenticationFailedException)
        {
            throw new HttpRequestException(
                "The render service access token could not be acquired.");
        }

        request.Headers.Remove("Authorization");
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", token.Token);

        return await base.SendAsync(request, cancellationToken);
    }

    internal static bool IsExpectedOrigin(Uri expected, Uri actual)
    {
        return string.Equals(
                expected.Scheme,
                actual.Scheme,
                StringComparison.OrdinalIgnoreCase) &&
            string.Equals(
                expected.IdnHost,
                actual.IdnHost,
                StringComparison.OrdinalIgnoreCase) &&
            expected.Port == actual.Port;
    }

    internal static bool IsLoopbackHttp(Uri uri)
    {
        return uri.IsLoopback &&
            string.Equals(
                uri.Scheme,
                Uri.UriSchemeHttp,
                StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryGetAbsoluteRequestUri(
        Uri baseUri,
        Uri? requestUri,
        out Uri absoluteRequestUri)
    {
        if (requestUri is null)
        {
            absoluteRequestUri = null!;
            return false;
        }

        if (requestUri.IsAbsoluteUri)
        {
            absoluteRequestUri = requestUri;
            return true;
        }

        return Uri.TryCreate(baseUri, requestUri, out absoluteRequestUri!);
    }
}
