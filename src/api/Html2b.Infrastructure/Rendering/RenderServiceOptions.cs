namespace Html2b.Infrastructure.Rendering;

public sealed class RenderServiceOptions
{
    public const string SectionName = "RenderService";

    public string BaseUrl { get; set; } = string.Empty;

    public string Audience { get; set; } = string.Empty;
}
