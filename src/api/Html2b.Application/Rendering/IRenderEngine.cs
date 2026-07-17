using Html2b.Domain.Rendering;

namespace Html2b.Application.Rendering;

public interface IRenderEngine
{
    Task<RenderedFile> RenderAsync(
        string html,
        RenderFormat format,
        CancellationToken cancellationToken);
}
