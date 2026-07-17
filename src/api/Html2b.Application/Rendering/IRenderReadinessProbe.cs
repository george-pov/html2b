namespace Html2b.Application.Rendering;

public interface IRenderReadinessProbe
{
    Task<bool> IsReadyAsync(CancellationToken cancellationToken);
}
