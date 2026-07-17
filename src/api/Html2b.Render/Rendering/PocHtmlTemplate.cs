namespace Html2b.Render.Rendering;

public static class PocHtmlTemplate
{
    public const string Html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Html2B rendering POC</title>
          <style>
            *, *::before, *::after { box-sizing: border-box; }
            html, body { margin: 0; width: 1280px; height: 720px; overflow: hidden; }
            body {
              display: grid;
              place-items: center;
              background: #14213d;
              color: #fca311;
              font: 700 64px/1.1 Arial, sans-serif;
              -webkit-print-color-adjust: exact;
              print-color-adjust: exact;
            }
            main { width: 1280px; text-align: center; }
          </style>
        </head>
        <body>
          <main>Hello from Html2B</main>
        </body>
        </html>
        """;
}
