# api-version: The results API reports its build

## ADDED Requirements

### Requirement: The API reports the build it is running

The results API SHALL serve `GET /version` with the scorecard-infra release
and commit it was built from, and the module and version of the workflow
parser it verifies uploads with. The route SHALL be documented in the
published contract.

#### Scenario: A release build is queried

- **WHEN** `/version` is requested from a server built by the release workflow
- **THEN** the response SHALL contain the release version, the full commit,
  and the parser module and version as linked

#### Scenario: Build identity was not supplied

- **WHEN** the server was built without the release and commit values
- **THEN** those fields SHALL read `unknown` rather than being empty, and the
  parser field SHALL still report the linked parser

### Requirement: Version responses are cacheable and cheap

The `/version` response SHALL carry CDN and browser cache directives and a
surrogate key, and SHALL be served without I/O.

#### Scenario: Repeated requests

- **WHEN** `/version` is requested repeatedly through the CDN
- **THEN** the CDN SHALL be permitted to cache the response for five minutes,
  and browsers for one minute

#### Scenario: Checking a deploy

- **WHEN** an operator needs the build serving right now
- **THEN** the surrogate key SHALL allow the cached copy to be purged, so the
  CDN serves the new build without bypassing it
