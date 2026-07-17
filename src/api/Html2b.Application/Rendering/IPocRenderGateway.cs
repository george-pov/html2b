using Html2b.Domain.Rendering;

namespace Html2b.Application.Rendering;

public interface IPocRenderGateway
{
    Task<RenderedFile> RenderAsync(
        RenderFormat format,
        CancellationToken cancellationToken);
}
