namespace Html2b.Application.Rendering;

public sealed class RenderGatewayException : Exception
{
    public RenderGatewayException(string message)
        : base(message)
    {
    }

    public RenderGatewayException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
