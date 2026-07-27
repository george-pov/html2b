# Local Development

Html2B runs the Azure Functions host on Windows and the Render host in a Linux
container.

## Prerequisites

- PowerShell 7.
- .NET 10 SDK.
- Azure Functions Core Tools 4.
- Azurite for the tracked `UseDevelopmentStorage=true` setting.
- Docker Desktop using Linux containers.
- Docker Compose v2.
- WSL 2 when Docker Desktop uses its WSL backend.

Visual Studio can start both hosts through the tracked solution launch profile.

## Configure the Functions Host

Create the ignored local settings file from the tracked sample:

```powershell
Copy-Item `
    src/api/Html2b.AzureFunctions/local.settings.sample.json `
    src/api/Html2b.AzureFunctions/local.settings.json
```

Set `RenderService__BaseUrl` in the copied file to:

```text
http://localhost:8081
```

The Functions host validates this value as an absolute HTTP or HTTPS URI during
startup.

## Restore and Build

Run from the repository root:

```powershell
dotnet restore src/api/Html2b.slnx
dotnet build src/api/Html2b.slnx --configuration Release --no-restore
```

The solution contains no automated test project.

## Run from the Command Line

Start Render:

```powershell
docker compose up --build html2b-render
```

Compose publishes Render on `127.0.0.1:8081`.

In another terminal, start the Functions host:

```powershell
Push-Location src/api/Html2b.AzureFunctions
func start --port 8080
Pop-Location
```

The Functions host listens on `http://localhost:8080`.

## Run from Visual Studio

1. Open `src/api/Html2b.slnx`.
2. Select the `Html2b local` solution launch profile.
3. Start debugging.

The profile starts Render in its Dockerfile-based container and starts the
Functions host through Core Tools.

## Verify the Hosts

Check process liveness and rendering readiness:

```powershell
Invoke-RestMethod http://localhost:8080/health/live
Invoke-RestMethod http://localhost:8080/health/ready
```

Create each supported output:

```powershell
Invoke-WebRequest `
    -Method Post `
    -Uri http://localhost:8080/api/renders/png `
    -OutFile render.png

Invoke-WebRequest `
    -Method Post `
    -Uri http://localhost:8080/api/renders/jpeg `
    -OutFile render.jpg

Invoke-WebRequest `
    -Method Post `
    -Uri http://localhost:8080/api/renders/pdf `
    -OutFile render.pdf
```

The health responses report `live` and `ready`. Each render request returns a
non-empty file with the content type documented in
[HTTP API](../api/http-api.md).

## Stop the Hosts

Stop Core Tools with Ctrl+C. Stop Render and remove the Compose network:

```powershell
docker compose down
```

## Common Local Failures

- If port 8081 is already in use, stop the existing Compose container before
  starting either local profile.
- If readiness returns `503`, wait for Chromium startup to complete and retry.
- If Functions startup rejects the Render URL, confirm the copied local setting
  contains the absolute local address shown above.
