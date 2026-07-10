# Repository Guidelines

## Project Structure & Module Organization

This repository is currently an early-stage .NET scaffold: only `.gitignore` is tracked, and no solution, source project, or test project has been added. Keep the root focused on solution-level files such as `html2b.sln`, `README.md`, and shared configuration. Place production projects under `src/` and matching test projects under `tests/`, for example:

```text
src/Html2B/Html2B.csproj
tests/Html2B.Tests/Html2B.Tests.csproj
```

Store project-owned assets beside the project that consumes them. Avoid committing generated `bin/`, `obj/`, `artifacts/`, coverage, or test-result directories; these are already ignored.

## Build, Test, and Development Commands

No build scripts or project files exist yet. After the solution is created, use standard .NET CLI commands from the repository root:

- `dotnet restore` — restore NuGet dependencies.
- `dotnet build --configuration Release` — compile the full solution with release settings.
- `dotnet test --configuration Release` — run all tests in the solution.
- `dotnet run --project src/Html2B` — run the main project locally (adjust the path if the project name changes).
- `dotnet format` — apply configured .NET formatting rules before review.

Update this section when repository-specific scripts or commands are introduced.

## Coding Style & Naming Conventions

Use four spaces for C# indentation and follow standard .NET naming: `PascalCase` for types, public members, and namespaces; `camelCase` for parameters and local variables; and `IName` for interfaces. Enable nullable reference types and implicit usings in new projects. Prefer one primary type per file, with the filename matching the type. Add an `.editorconfig` when the first project is created and treat formatter or analyzer warnings as issues to resolve.

## Testing Guidelines

Create a dedicated test project under `tests/` for each production project. Name test files after the subject, such as `HtmlConverterTests.cs`, and test methods by behavior, such as `Convert_EmptyInput_ReturnsEmptyOutput`. Add regression tests with bug fixes. No coverage threshold is currently defined; prioritize meaningful coverage of parsing, conversion, and error paths.

## Commit & Pull Request Guidelines

Git history currently contains only `Initial commit`, so no established message convention exists. Use short, imperative subjects such as `Add HTML conversion pipeline`, and keep each commit focused. Pull requests should explain the change and validation performed, link related issues, and include sample input/output or screenshots when behavior or rendered output changes. Keep secrets out of commits; `.env` is ignored for local configuration.
