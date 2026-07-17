using System.Net;
using System.Net.Http.Json;

using Html2b.Application.Rendering;
using Html2b.Contracts.Rendering;
using Html2b.Domain.Rendering;

namespace Html2b.Infrastructure.Rendering;

public sealed class PocRenderHttpClient(HttpClient httpClient) :
    IPocRenderGateway,
    IRenderReadinessProbe
{
    public static readonly TimeSpan RenderTimeout = TimeSpan.FromSeconds(75);
    public static readonly TimeSpan ReadinessTimeout = TimeSpan.FromSeconds(2);
    public const int MaxResponseBytes = 16 * 1024 * 1024;

    public async Task<RenderedFile> RenderAsync(
        RenderFormat format,
        CancellationToken cancellationToken)
    {
        using var timeoutSource =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(RenderTimeout);
        var linkedToken = timeoutSource.Token;

        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                "/internal/renders")
            {
                Content = JsonContent.Create(
                    new PocRenderRequestV1(format.Value)),
            };
            using var response = await httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                linkedToken);

            if (!response.IsSuccessStatusCode)
            {
                throw new RenderGatewayException(
                    "The render service returned an unsuccessful response.");
            }

            if (response.Content.Headers.ContentLength is > MaxResponseBytes)
            {
                throw new RenderGatewayException(
                    "The render service returned an oversized response.");
            }

            var contentType = response.Content.Headers.ContentType?.MediaType;
            var fileName =
                response.Content.Headers.ContentDisposition?.FileNameStar ??
                response.Content.Headers.ContentDisposition?.FileName;

            if (string.IsNullOrWhiteSpace(contentType) ||
                string.IsNullOrWhiteSpace(fileName))
            {
                throw new RenderGatewayException(
                    "The render service returned invalid response metadata.");
            }

            await response.Content.LoadIntoBufferAsync(
                MaxResponseBytes,
                linkedToken);
            var content = await response.Content.ReadAsByteArrayAsync(linkedToken);

            return new RenderedFile(
                content,
                contentType,
                fileName.Trim('"'));
        }
        catch (OperationCanceledException exception)
            when (!cancellationToken.IsCancellationRequested)
        {
            throw new RenderGatewayException(
                "The render service did not respond in time.",
                exception);
        }
        catch (HttpRequestException exception)
        {
            throw new RenderGatewayException(
                "The render service request failed.",
                exception);
        }
        catch (IOException exception)
        {
            throw new RenderGatewayException(
                "The render service response could not be read.",
                exception);
        }
        catch (ArgumentException exception)
        {
            throw new RenderGatewayException(
                "The render service returned an invalid response.",
                exception);
        }
    }

    public async Task<bool> IsReadyAsync(CancellationToken cancellationToken)
    {
        using var timeoutSource =
            CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(ReadinessTimeout);

        try
        {
            using var response = await httpClient.GetAsync(
                "/health/ready",
                HttpCompletionOption.ResponseHeadersRead,
                timeoutSource.Token);

            return response.StatusCode == HttpStatusCode.OK;
        }
        catch (OperationCanceledException)
            when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (HttpRequestException)
        {
            return false;
        }
    }
}
