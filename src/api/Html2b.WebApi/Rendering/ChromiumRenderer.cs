using System.Diagnostics;

using Microsoft.Playwright;

namespace Html2b.WebApi.Rendering;

public sealed class ChromiumRenderer(ILogger<ChromiumRenderer> logger)
{
    private const int ViewportWidth = 1280;
    private const int ViewportHeight = 720;
    private const int OperationTimeoutMilliseconds = 15000;

    public async Task<byte[]> RenderPngAsync(
        string html,
        CancellationToken cancellationToken)
    {
        var renderId = Guid.NewGuid();
        var stopwatch = Stopwatch.StartNew();

        logger.LogInformation("Starting PNG render {RenderId}", renderId);

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var playwright = await Playwright.CreateAsync();

            cancellationToken.ThrowIfCancellationRequested();
            await using var browser = await playwright.Chromium.LaunchAsync();

            cancellationToken.ThrowIfCancellationRequested();
            await using var context = await CreateContextAsync(browser);
            await BlockExternalRequestsAsync(context);

            cancellationToken.ThrowIfCancellationRequested();
            var page = await context.NewPageAsync();

            try
            {
                page.SetDefaultTimeout(OperationTimeoutMilliseconds);
                page.SetDefaultNavigationTimeout(OperationTimeoutMilliseconds);

                cancellationToken.ThrowIfCancellationRequested();
                await page.SetContentAsync(
                    html,
                    new PageSetContentOptions
                    {
                        WaitUntil = WaitUntilState.Load,
                        Timeout = OperationTimeoutMilliseconds,
                    });

                cancellationToken.ThrowIfCancellationRequested();
                var bytes = await page.ScreenshotAsync(
                    new PageScreenshotOptions
                    {
                        Type = ScreenshotType.Png,
                        Animations = ScreenshotAnimations.Disabled,
                        Scale = ScreenshotScale.Css,
                        Timeout = OperationTimeoutMilliseconds,
                    });

                logger.LogInformation(
                    "Completed PNG render {RenderId} in {ElapsedMilliseconds} ms",
                    renderId,
                    stopwatch.ElapsedMilliseconds);

                return bytes;
            }
            finally
            {
                if (!page.IsClosed)
                {
                    await page.CloseAsync();
                }
            }
        }
        catch (Exception exception)
        {
            logger.LogError(
                exception,
                "PNG render {RenderId} failed after {ElapsedMilliseconds} ms",
                renderId,
                stopwatch.ElapsedMilliseconds);
            throw;
        }
    }

    private static Task<IBrowserContext> CreateContextAsync(IBrowser browser)
    {
        return browser.NewContextAsync(
            new BrowserNewContextOptions
            {
                ViewportSize = new ViewportSize
                {
                    Width = ViewportWidth,
                    Height = ViewportHeight,
                },
                DeviceScaleFactor = 1,
                JavaScriptEnabled = false,
                ServiceWorkers = ServiceWorkerPolicy.Block,
                AcceptDownloads = false,
            });
    }

    private static async Task BlockExternalRequestsAsync(IBrowserContext context)
    {
        await context.RouteAsync("http://**/*", route => route.AbortAsync());
        await context.RouteAsync("https://**/*", route => route.AbortAsync());
    }
}
