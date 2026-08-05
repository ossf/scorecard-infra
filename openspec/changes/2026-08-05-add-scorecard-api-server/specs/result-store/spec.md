# result-store: Added Requirements

## ADDED Requirements

### Requirement: Cloud-agnostic blob storage

Results SHALL be persisted and retrieved through a blob-storage abstraction that
supports S3-compatible, Azure Blob, Google Cloud Storage,
local-filesystem, and in-memory backends, with the backend selected by a storage URL.

#### Scenario: Backend selected by URL scheme

- **WHEN** the storage URL specifies a supported backend (e.g. `s3://`, `azblob://`,
  `gs://`, `file://`, `mem://`)
- **THEN** the store SHALL read and write results using that backend without code changes

### Requirement: Configuration via environment, no hardcoded bucket

The storage location SHALL be provided by an environment variable, and the server
SHALL NOT contain a hardcoded bucket location.

#### Scenario: Bucket configured via environment

- **WHEN** the storage URL environment variable is set to a valid bucket
- **THEN** the store SHALL use that bucket

#### Scenario: Missing storage configuration

- **WHEN** the storage URL environment variable is unset or invalid
- **THEN** the server SHALL fail fast at startup with an actionable error

### Requirement: Object key contract

The store SHALL address results using the keys `{host}/{org}/{repo}/results.json` for
the latest result and `{host}/{org}/{repo}/{commit}/results.json` for a commit-pinned
result.

#### Scenario: Latest key

- **WHEN** a latest result is stored or retrieved
- **THEN** the store SHALL use the `{host}/{org}/{repo}/results.json` key

#### Scenario: Commit-pinned key

- **WHEN** a commit-pinned result is stored or retrieved
- **THEN** the store SHALL use the `{host}/{org}/{repo}/{commit}/results.json` key

### Requirement: Canonical JSON2 bodies

Stored result bodies SHALL be canonical Scorecard JSON2, so the same objects are
servable by a Scorecard-webapp-compatible reader.

#### Scenario: Stored body is JSON2

- **WHEN** a result is written to the store
- **THEN** its body SHALL be canonical Scorecard JSON2

### Requirement: Miss is reported distinctly

The store SHALL report a not-found condition distinguishable from an I/O error when a
key does not exist.

#### Scenario: Key absent

- **WHEN** a requested key does not exist in the bucket
- **THEN** the store SHALL return a not-found sentinel rather than a generic error
