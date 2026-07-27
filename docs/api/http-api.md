# Html2B HTTP API

Html2B exposes health and rendering endpoints from the Functions host. The
Render host exposes the corresponding service endpoints used by the
Functions-side HTTP client.

## Functions Host Endpoints

| Method | Route | Success |
| --- | --- | --- |
| `GET` | `/health/live` | `200 OK` with `{"status":"live"}` |
| `GET` | `/health/ready` | `200 OK` with `{"status":"ready"}` |
| `POST` | `/api/renders/png` | `200 OK` with `image/png` |
| `POST` | `/api/renders/jpeg` | `200 OK` with `image/jpeg` |
| `POST` | `/api/renders/pdf` | `200 OK` with `application/pdf` |

The render routes do not read a request body. The selected route determines the
output format.

### Readiness Failure

When Render or Chromium is not ready, `GET /health/ready` returns:

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
```

```json
{
  "status": "not-ready"
}
```

### Unsupported Format

A format other than `png`, `jpeg`, or `pdf` returns `400 Bad Request` problem
details with the title `Unsupported output format`.

### Render Service Failure

When the Functions host cannot obtain a valid render response, it returns
`503 Service Unavailable` problem details with the title
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

## Output Characteristics

| Format | Content type | Output settings |
| --- | --- | --- |
| PNG | `image/png` | 1280 by 720 |
| JPEG | `image/jpeg` | 1280 by 720, quality 90 |
| PDF | `application/pdf` | 1280 by 720, background graphics, zero margins |

The service buffers rendered files in memory and enforces a 16 MiB response
limit between the two hosts.
