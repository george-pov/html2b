# Html2B HTTP API

Html2B exposes health and rendering endpoints from the Functions host. The
Render host exposes the corresponding service endpoints used by the
Functions-side HTTP client.

## Functions Host Endpoints

| Method | Route | Authorization | Success |
| --- | --- | --- | --- |
| `GET` | `/health/live` | Anonymous | `200 OK` with `{"status":"live"}` |
| `GET` | `/health/ready` | Function key | `200 OK` with `{"status":"ready"}` |
| `POST` | `/api/renders/png` | Function key | `200 OK` with `image/png` |
| `POST` | `/api/renders/jpeg` | Function key | `200 OK` with `image/jpeg` |
| `POST` | `/api/renders/pdf` | Function key | `200 OK` with `application/pdf` |

The render routes do not read a request body. The selected route determines the
output format.

For readiness and rendering, send the Function key in the standard header:

```http
x-functions-key: <function-key>
```

The placeholder is not a working credential. Do not place a real key in source
or saved request files.

On the deployed Functions host, readiness and render requests without an
accepted key return `401 Unauthorized` before the trigger runs or a Render
dependency call is made. Process liveness remains available without a key.

### Readiness Failure

For an authorized request, when Render or Chromium is not ready,
`GET /health/ready` returns:

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
```

```json
{
  "status": "not-ready"
}
```

After Render scales to zero, the first authorized readiness request can return
this response while Chromium starts. A later request returns `200 OK` after
readiness converges.

### Unsupported Format

For an authorized request, a format other than `png`, `jpeg`, or `pdf` returns
`400 Bad Request` problem details with the title
`Unsupported output format`.

### Render Service Failure

For an authorized request, when the Functions host cannot obtain a valid render
response, it returns `503 Service Unavailable` problem details with the title
`Render service unavailable`.

## Render Host Endpoints

| Method | Route | Behavior |
| --- | --- | --- |
| `GET` | `/health/live` | Reports that the Render process is running. |
| `GET` | `/health/ready` | Reports whether the hosted Chromium process is connected. |
| `POST` | `/internal/renders` | Renders the built-in HTML in the requested format. |

The render request is JSON:

```json
{
  "format": "png"
}
```

The accepted format values are `png`, `jpeg`, and `pdf`. An unsupported value
returns `400 Bad Request`. A rendering failure returns
`500 Internal Server Error`.

Successful render responses include the file bytes, the format-specific
content type, and attachment metadata.

In Azure, the Render host has a public HTTPS hostname protected by Container
Apps authentication. A direct request with no token, a malformed token, or a
wrong-audience token returns `401 Unauthorized` before the Render endpoint
runs. The policy validates the configured Render audience and permits the
Functions host's managed identity. Local loopback requests are token-free as
described in [Local development](../development/local-development.md).

## Output Characteristics

| Format | Content type | Output settings |
| --- | --- | --- |
| PNG | `image/png` | 1280 by 720 |
| JPEG | `image/jpeg` | 1280 by 720, quality 90 |
| PDF | `application/pdf` | 1280 by 720 CSS pixels (960 by 540 points), background graphics, zero margins |

The service buffers rendered files in memory and enforces a 16 MiB response
limit between the two hosts.
