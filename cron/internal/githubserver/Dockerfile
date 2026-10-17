# Copyright 2021 OpenSSF Scorecard Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM golang:1.27.1@sha256:162be5298a40ed317005c8339c6de4d10d3eef336d66dc8e9259b03ab9d3a6d2 AS base
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.* ./
RUN go mod download
COPY . ./

FROM base AS authserver
ARG TARGETOS
ARG TARGETARCH
ARG GIT_HASH
ARG GIT_VERSION
ARG GIT_TREESTATE
ARG SOURCE_DATE_EPOCH
ARG SCORECARD_ENGINE_COMMIT
RUN CGO_ENABLED=0 make build-github-server

FROM gcr.io/distroless/base:nonroot@sha256:0896741ba5bafd3ac87ea025a5f578952f2d238ddc3614cb368acc983a687aa2
COPY --from=authserver /src/cron/internal/githubserver/github-auth-server cron/internal/githubserver/github-auth-server
ENTRYPOINT ["cron/internal/githubserver/github-auth-server"]
