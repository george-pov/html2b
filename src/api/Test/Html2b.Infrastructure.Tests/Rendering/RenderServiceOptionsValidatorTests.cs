using Html2b.Infrastructure.Rendering;

namespace Html2b.Infrastructure.Tests.Rendering;

public sealed class RenderServiceOptionsValidatorTests
{
    private const string Audience =
        "api://11111111-1111-1111-1111-111111111111";

    private readonly RenderServiceOptionsValidator validator = new();

    [Theory]
    [InlineData("http://localhost:8081")]
    [InlineData("http://127.0.0.1:8081")]
    [InlineData("http://127.0.0.2:8081")]
    [InlineData("http://[::1]:8081")]
    public void Validate_LoopbackHttpWithoutAudience_Succeeds(
        string baseUrl)
    {
        var result = Validate(baseUrl, string.Empty);

        Assert.True(result.Succeeded);
    }

    [Fact]
    public void Validate_LoopbackHttpWithAudience_Fails()
    {
        var result = Validate("http://localhost:8081", Audience);

        AssertFailureContains(result, "Audience must be empty");
    }

    [Fact]
    public void Validate_LoopbackHttpWithWhitespaceAudience_Fails()
    {
        var result = Validate("http://localhost:8081", " ");

        AssertFailureContains(result, "Audience must be empty");
    }

    [Theory]
    [InlineData("http://render.example.test", "")]
    [InlineData("http://render.example.test", Audience)]
    public void Validate_NonLoopbackHttp_Fails(
        string baseUrl,
        string audience)
    {
        var result = Validate(baseUrl, audience);

        AssertFailureContains(result, "cannot use HTTP");
    }

    [Fact]
    public void Validate_RemoteHttpsWithoutAudience_Fails()
    {
        var result = Validate(
            "https://render.example.test",
            string.Empty);

        AssertFailureContains(result, "Audience is required");
    }

    [Theory]
    [InlineData("https://render.example.test")]
    [InlineData("https://localhost:8443")]
    public void Validate_RemoteHttpsWithApplicationIdAudience_Succeeds(
        string baseUrl)
    {
        var result = Validate(baseUrl, Audience);

        Assert.True(result.Succeeded);
    }

    [Fact]
    public void Validate_RemoteHttpsWithUppercaseGuidAudience_Succeeds()
    {
        var result = Validate(
            "https://render.example.test",
            "api://AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE");

        Assert.True(result.Succeeded);
    }

    [Theory]
    [InlineData(" ")]
    [InlineData("11111111-1111-1111-1111-111111111111")]
    [InlineData("API://11111111-1111-1111-1111-111111111111")]
    [InlineData("api://11111111111111111111111111111111")]
    [InlineData("api://11111111-1111-1111-1111-111111111111/")]
    [InlineData("api://11111111-1111-1111-1111-111111111111/.default")]
    [InlineData(" api://11111111-1111-1111-1111-111111111111")]
    [InlineData("api://11111111-1111-1111-1111-111111111111 ")]
    public void Validate_RemoteHttpsWithMalformedAudience_Fails(
        string audience)
    {
        var result = Validate(
            "https://render.example.test",
            audience);

        AssertFailureContains(
            result,
            "must be exactly api://<D-format-guid>");
    }

    [Theory]
    [InlineData("")]
    [InlineData("render.example.test")]
    [InlineData("/relative")]
    [InlineData("ftp://render.example.test")]
    [InlineData("file:///render")]
    [InlineData("not a URI")]
    public void Validate_InvalidBaseUrl_Fails(string baseUrl)
    {
        var result = Validate(baseUrl, string.Empty);

        AssertFailureContains(
            result,
            "must be an absolute HTTP or HTTPS URI");
    }

    private Microsoft.Extensions.Options.ValidateOptionsResult Validate(
        string baseUrl,
        string audience)
    {
        return validator.Validate(
            null,
            new RenderServiceOptions
            {
                BaseUrl = baseUrl,
                Audience = audience,
            });
    }

    private static void AssertFailureContains(
        Microsoft.Extensions.Options.ValidateOptionsResult result,
        string expected)
    {
        Assert.False(result.Succeeded);
        Assert.Contains(
            expected,
            Assert.Single(result.Failures!),
            StringComparison.Ordinal);
    }
}
