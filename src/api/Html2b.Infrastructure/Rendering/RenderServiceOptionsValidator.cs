using Microsoft.Extensions.Options;

namespace Html2b.Infrastructure.Rendering;

public sealed class RenderServiceOptionsValidator :
    IValidateOptions<RenderServiceOptions>
{
    private const string ApplicationIdUriPrefix = "api://";

    public ValidateOptionsResult Validate(
        string? name,
        RenderServiceOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (!TryGetBaseUri(options.BaseUrl, out var baseUri))
        {
            return ValidateOptionsResult.Fail(
                $"{RenderServiceOptions.SectionName}:BaseUrl must be an absolute HTTP or HTTPS URI.");
        }

        if (string.Equals(
                baseUri.Scheme,
                Uri.UriSchemeHttp,
                StringComparison.OrdinalIgnoreCase))
        {
            if (!baseUri.IsLoopback)
            {
                return ValidateOptionsResult.Fail(
                    $"{RenderServiceOptions.SectionName}:BaseUrl cannot use HTTP unless it is a loopback URI.");
            }

            if (!string.IsNullOrEmpty(options.Audience))
            {
                return ValidateOptionsResult.Fail(
                    $"{RenderServiceOptions.SectionName}:Audience must be empty when BaseUrl uses loopback HTTP.");
            }

            return ValidateOptionsResult.Success;
        }

        if (string.IsNullOrEmpty(options.Audience))
        {
            return ValidateOptionsResult.Fail(
                $"{RenderServiceOptions.SectionName}:Audience is required when BaseUrl uses HTTPS.");
        }

        if (!TryGetAudienceClientId(options.Audience, out _))
        {
            return ValidateOptionsResult.Fail(
                $"{RenderServiceOptions.SectionName}:Audience must be exactly api://<D-format-guid> when BaseUrl uses HTTPS.");
        }

        return ValidateOptionsResult.Success;
    }

    internal static bool TryGetBaseUri(string value, out Uri baseUri)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out var candidate) &&
            (string.Equals(
                 candidate.Scheme,
                 Uri.UriSchemeHttp,
                 StringComparison.OrdinalIgnoreCase) ||
             string.Equals(
                 candidate.Scheme,
                 Uri.UriSchemeHttps,
                 StringComparison.OrdinalIgnoreCase)))
        {
            baseUri = candidate;
            return true;
        }

        baseUri = null!;
        return false;
    }

    internal static bool TryGetAudienceClientId(
        string audience,
        out Guid clientId)
    {
        const int guidLength = 36;

        if (audience.Length != ApplicationIdUriPrefix.Length + guidLength ||
            !audience.StartsWith(
                ApplicationIdUriPrefix,
                StringComparison.Ordinal))
        {
            clientId = default;
            return false;
        }

        var value = audience[ApplicationIdUriPrefix.Length..];

        return Guid.TryParseExact(value, "D", out clientId) &&
            string.Equals(
                value,
                clientId.ToString("D"),
                StringComparison.OrdinalIgnoreCase);
    }
}
