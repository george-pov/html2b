using System.Diagnostics;

using Html2b.Application.Rendering;
using Html2b.Domain.Rendering;

using Microsoft.Playwright;

namespace Html2b.Render.Rendering;

public sealed class ChromiumRenderer(ILogger<ChromiumRenderer> logger) :
    IRenderEngine,
    IHostedService,
    IAsyncDisposable
{
    private const int ViewportWidth = 1280;
    private const int ViewportHeight = 720;
    private const int OperationTimeoutMilliseconds = 15000;

    private IPlaywright? _playwright;
    private IBrowser? _browser;
    private readonly SemaphoreSlim _renderGate = new(1, 1);
    private bool _isReady;
    private int _isDisposed;

    public bool IsReady
    {
        get
        {
            var browser = Volatile.Read(ref _browser);
            return Volatile.Read(ref _isReady) &&
                browser is { IsConnected: true };
        }
    }

    private IBrowser Browser
    {
        get
        {
            var browser = Volatile.Read(ref _browser);

            if (!Volatile.Read(ref _isReady) ||
                browser is not { IsConnected: true })
            {
                throw new InvalidOperationException(
                    "Chromium startup has not completed or the browser is no longer connected.");
            }

            return browser;
        }
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref _isDisposed) != 0,
            this);

        if (_playwright is not null || _browser is not null)
        {
            throw new InvalidOperationException("Chromium has already been started.");
        }

        logger.LogInformation("Starting hosted Chromium browser");

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            _playwright = await Playwright.CreateAsync();

            cancellationToken.ThrowIfCancellationRequested();
            _browser = await _playwright.Chromium.LaunchAsync();

            cancellationToken.ThrowIfCancellationRequested();
            Volatile.Write(ref _isReady, true);

            logger.LogInformation("Hosted Chromium browser is ready");
        }
        catch (Exception exception)
        {
            Volatile.Write(ref _isReady, false);

            try
            {
                await CloseBrowserAsync();
            }
            catch (Exception cleanupException)
            {
                logger.LogError(
                    cleanupException,
                    "Hosted Chromium cleanup failed after startup failure");
            }

            logger.LogError(exception, "Hosted Chromium browser failed to start");
            throw;
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        Volatile.Write(ref _isReady, false);
        logger.LogInformation("Stopping hosted Chromium browser");

        await CloseBrowserAsync();

        logger.LogInformation("Hosted Chromium browser stopped");
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _isDisposed, 1) != 0)
        {
            return;
        }

        Volatile.Write(ref _isReady, false);

        try
        {
            await CloseBrowserAsync();
        }
        finally
        {
            _renderGate.Dispose();
        }
    }

    public async Task<RenderedFile> RenderAsync(
        string html,
        RenderFormat format,
        CancellationToken cancellationToken)
    {
        var renderId = Guid.NewGuid();
        var stopwatch = Stopwatch.StartNew();
        var gateAcquired = false;

        logger.LogInformation(
            "Waiting to start {Format} render {RenderId}",
            format.Value,
            renderId);

        try
        {
            await _renderGate.WaitAsync(cancellationToken);
            gateAcquired = true;

            cancellationToken.ThrowIfCancellationRequested();
            var browser = Browser;

            logger.LogInformation(
                "Starting {Format} render {RenderId}",
                format.Value,
                renderId);

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
                var renderedFile = format.Value switch
                {
                    "png" or "jpeg" => await CaptureScreenshotAsync(page, format),
                    "pdf" => await CreatePdfAsync(page),
                    _ => throw new ArgumentOutOfRangeException(nameof(format)),
                };

                logger.LogInformation(
                    "Completed {Format} render {RenderId} in {ElapsedMilliseconds} ms",
                    format.Value,
                    renderId,
                    stopwatch.ElapsedMilliseconds);

                return renderedFile;
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
                format.Value,
                renderId,
                stopwatch.ElapsedMilliseconds);
            throw;
        }
        finally
        {
            if (gateAcquired)
            {
                _renderGate.Release();
            }
        }
    }

    private async Task CloseBrowserAsync()
    {
        await _renderGate.WaitAsync();

        try
        {
            var browser = Interlocked.Exchange(ref _browser, null);
            var playwright = Interlocked.Exchange(ref _playwright, null);

            try
            {
                if (browser is not null)
                {
                    await browser.CloseAsync().WaitAsync(
                        TimeSpan.FromMilliseconds(OperationTimeoutMilliseconds));
                }
            }
            finally
            {
                playwright?.Dispose();
            }
        }
        finally
        {
            _renderGate.Release();
        }
    }

    private static async Task<RenderedFile> CaptureScreenshotAsync(
        IPage page,
        RenderFormat format)
    {
        var type = format.Value switch
        {
            "png" => ScreenshotType.Png,
            "jpeg" => ScreenshotType.Jpeg,
            _ => throw new ArgumentOutOfRangeException(nameof(format)),
        };

        var options = new PageScreenshotOptions
        {
            Type = type,
            Animations = ScreenshotAnimations.Disabled,
            Scale = ScreenshotScale.Css,
            Timeout = OperationTimeoutMilliseconds,
        };

        if (format == RenderFormat.Jpeg)
        {
            options.Quality = 90;
        }

        var content = await page.ScreenshotAsync(options);

        return new RenderedFile(
            content,
            format == RenderFormat.Png ? "image/png" : "image/jpeg",
            format == RenderFormat.Png
                ? "html2b-poc.png"
                : "html2b-poc.jpg");
    }

    private static async Task<RenderedFile> CreatePdfAsync(IPage page)
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

        var content = await pdfTask.WaitAsync(
            TimeSpan.FromMilliseconds(OperationTimeoutMilliseconds));

        return new RenderedFile(
            content,
            "application/pdf",
            "html2b-poc.pdf");
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
