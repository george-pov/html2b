ARG PLAYWRIGHT_VERSION=1.61.0

FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src
COPY ["src/api/Html2b.WebApi/Html2b.WebApi.csproj", "src/api/Html2b.WebApi/"]
RUN dotnet restore "src/api/Html2b.WebApi/Html2b.WebApi.csproj"
COPY . .
RUN dotnet publish "src/api/Html2b.WebApi/Html2b.WebApi.csproj" \
    --configuration $BUILD_CONFIGURATION \
    --output /app/publish \
    --no-restore \
    /p:UseAppHost=false

FROM mcr.microsoft.com/playwright/dotnet:v${PLAYWRIGHT_VERSION}-noble AS final
USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*
ENV ASPNETCORE_URLS=http://+:8080 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
WORKDIR /app
EXPOSE 8080
COPY --from=build --chown=pwuser:pwuser /app/publish .
USER pwuser
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail --silent --show-error http://localhost:8080/health/live || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "dotnet", "Html2b.WebApi.dll"]
