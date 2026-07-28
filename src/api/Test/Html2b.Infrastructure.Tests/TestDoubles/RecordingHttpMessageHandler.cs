using System.Net.Http.Headers;

namespace Html2b.Infrastructure.Tests.TestDoubles;

public sealed record RecordedHttpRequest(
    HttpMethod Method,
    Uri RequestUri,
    string? AuthorizationScheme,
    string? AuthorizationParameter);

public sealed class RecordingHttpMessageHandler : HttpMessageHandler
{
    private readonly object sync = new();
    private readonly List<RecordedHttpRequest> requests = [];
    private readonly Queue<
        Func<CancellationToken, Task<HttpResponseMessage>>> responses = [];

    public Func<
        HttpRequestMessage,
        CancellationToken,
        Task<HttpResponseMessage>>?
        Responder
    {
        get;
        set;
    }

    public IReadOnlyList<RecordedHttpRequest> Requests
    {
        get
        {
            lock (sync)
            {
                return [.. requests];
            }
        }
    }

    public void EnqueueResponse(HttpResponseMessage response)
    {
        ArgumentNullException.ThrowIfNull(response);

        lock (sync)
        {
            responses.Enqueue(
                _ => Task.FromResult(response));
        }
    }

    public void EnqueueException(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        lock (sync)
        {
            responses.Enqueue(
                _ => Task.FromException<HttpResponseMessage>(exception));
        }
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        if (request.RequestUri is not { IsAbsoluteUri: true } requestUri)
        {
            throw new InvalidOperationException(
                "The recorded request URI must be absolute.");
        }

        var authorization = request.Headers.Authorization;
        var recordedRequest = new RecordedHttpRequest(
            new HttpMethod(request.Method.Method),
            new Uri(requestUri.AbsoluteUri, UriKind.Absolute),
            authorization?.Scheme,
            authorization?.Parameter);

        Func<CancellationToken, Task<HttpResponseMessage>>? queuedResponse = null;

        lock (sync)
        {
            requests.Add(recordedRequest);

            if (responses.Count > 0)
            {
                queuedResponse = responses.Dequeue();
            }
        }

        if (Responder is not null)
        {
            return await Responder(request, cancellationToken);
        }

        if (queuedResponse is null)
        {
            throw new InvalidOperationException(
                "No response or exception was configured.");
        }

        return await queuedResponse(cancellationToken);
    }
}
