namespace Html2b.Domain.Rendering;

public sealed record RenderFormat
{
    private RenderFormat(string value)
    {
        Value = value;
    }

    public static RenderFormat Png { get; } = new("png");

    public static RenderFormat Jpeg { get; } = new("jpeg");

    public static RenderFormat Pdf { get; } = new("pdf");

    private static readonly IReadOnlyList<string> Values =
        [Png.Value, Jpeg.Value, Pdf.Value];

    public static IReadOnlyList<string> SupportedValues => Values;

    public string Value { get; }

    public static bool TryParse(string? value, out RenderFormat format)
    {
        if (string.Equals(value, Png.Value, StringComparison.OrdinalIgnoreCase))
        {
            format = Png;
            return true;
        }

        if (string.Equals(value, Jpeg.Value, StringComparison.OrdinalIgnoreCase))
        {
            format = Jpeg;
            return true;
        }

        if (string.Equals(value, Pdf.Value, StringComparison.OrdinalIgnoreCase))
        {
            format = Pdf;
            return true;
        }

        format = null!;
        return false;
    }

    public override string ToString()
    {
        return Value;
    }
}
