using Azure.Core;
using Azure.Identity;

namespace Html2b.Infrastructure.Tests.TestDoubles;

public sealed class FakeTokenCredential : TokenCredential
{
    private readonly object sync = new();
    private readonly List<IReadOnlyList<string>> requestedScopes = [];

    public string Token { get; set; } = "test-token";

    public AuthenticationFailedException? ExceptionToThrow { get; set; }

    public Func<
        TokenRequestContext,
        CancellationToken,
        ValueTask<AccessToken>>?
        Responder
    {
        get;
        set;
    }

    public IReadOnlyList<IReadOnlyList<string>> RequestedScopes
    {
        get
        {
            lock (sync)
            {
                return requestedScopes
                    .Select(scopes => (IReadOnlyList<string>)[.. scopes])
                    .ToArray();
            }
        }
    }

    public int RequestCount
    {
        get
        {
            lock (sync)
            {
                return requestedScopes.Count;
            }
        }
    }

    public override AccessToken GetToken(
        TokenRequestContext requestContext,
        CancellationToken cancellationToken)
    {
        RecordRequest(requestContext);
        cancellationToken.ThrowIfCancellationRequested();

        if (ExceptionToThrow is not null)
        {
            throw ExceptionToThrow;
        }

        return CreateToken();
    }

    public override async ValueTask<AccessToken> GetTokenAsync(
        TokenRequestContext requestContext,
        CancellationToken cancellationToken)
    {
        RecordRequest(requestContext);
        cancellationToken.ThrowIfCancellationRequested();

        if (ExceptionToThrow is not null)
        {
            throw ExceptionToThrow;
        }

        if (Responder is not null)
        {
            return await Responder(requestContext, cancellationToken);
        }

        return CreateToken();
    }

    private AccessToken CreateToken()
    {
        return new AccessToken(
            Token,
            DateTimeOffset.UtcNow.AddHours(1));
    }

    private void RecordRequest(TokenRequestContext requestContext)
    {
        lock (sync)
        {
            requestedScopes.Add([.. requestContext.Scopes]);
        }
    }
}
