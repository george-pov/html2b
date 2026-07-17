namespace Html2b.Application.Rendering;

public sealed class RenderedFile
{
    public RenderedFile(
        byte[] content,
        string contentType,
        string fileName)
    {
        ArgumentNullException.ThrowIfNull(content);

        if (content.Length == 0)
        {
            throw new ArgumentException(
                "Rendered content cannot be empty.",
                nameof(content));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(contentType);
        ArgumentException.ThrowIfNullOrWhiteSpace(fileName);

        Content = content;
        ContentType = contentType;
        FileName = fileName;
    }

    public byte[] Content { get; }

    public string ContentType { get; }

    public string FileName { get; }
}
