using System.Diagnostics;

using Microsoft.Playwright;

namespace Html2b.WebApi.Rendering;

public sealed class ChromiumRenderer(ILogger<ChromiumRenderer> logger)
{
    private const int ViewportWidth = 1280;
    private const int ViewportHeight = 720;
    private const int OperationTimeoutMilliseconds = 15000;

    public async Task<byte[]> RenderAsync(
        string html,
        RenderFormat format,
        CancellationToken cancellationToken)
    {
        var renderId = Guid.NewGuid();
        var stopwatch = Stopwatch.StartNew();

        logger.LogInformation(
            "Starting {Format} render {RenderId}",
            format,
            renderId);

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
                var bytes = format switch
                {
                    RenderFormat.Png => await CaptureScreenshotAsync(page, format),
                    RenderFormat.Jpeg => await CaptureScreenshotAsync(page, format),
                    RenderFormat.Pdf => await CreatePdfAsync(page),
                    _ => throw new ArgumentOutOfRangeException(nameof(format)),
                };

                logger.LogInformation(
                    "Completed {Format} render {RenderId} in {ElapsedMilliseconds} ms",
                    format,
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
                "{Format} render {RenderId} failed after {ElapsedMilliseconds} ms",
                format,
                renderId,
                stopwatch.ElapsedMilliseconds);
            throw;
        }
    }

    private static Task<byte[]> CaptureScreenshotAsync(
        IPage page,
        RenderFormat format)
    {
        var options = new PageScreenshotOptions
        {
            Type = format switch
            {
                RenderFormat.Png => ScreenshotType.Png,
                RenderFormat.Jpeg => ScreenshotType.Jpeg,
                _ => throw new ArgumentOutOfRangeException(nameof(format)),
            },
            Animations = ScreenshotAnimations.Disabled,
            Scale = ScreenshotScale.Css,
            Timeout = OperationTimeoutMilliseconds,
        };

        if (format == RenderFormat.Jpeg)
        {
            options.Quality = 90;
        }

        return page.ScreenshotAsync(options);
    }

    private static async Task<byte[]> CreatePdfAsync(IPage page)
    {
        await page.EmulateMediaAsync(
            new PageEmulateMediaOptions
            {
                Media = Media.Screen,
            });

        var pdfTask = page.PdfAsync(
            new PagePdfOptions
            {
                Width = "1280px",
                Height = "720px",
                Margin = new Margin
                {
                    Top = "0",
                    Right = "0",
                    Bottom = "0",
                    Left = "0",
                },
                PrintBackground = true,
            });

        return await pdfTask.WaitAsync(
            TimeSpan.FromMilliseconds(OperationTimeoutMilliseconds));
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
