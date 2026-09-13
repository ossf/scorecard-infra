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

FROM golang:1.27.0@sha256:0ecdc2a9f6156af6451080bfe3d8382a662fcc4e209608c6f919e643453514c1 AS builder
ENV APP_ROOT=/opt/app-root
ENV GOPATH=$APP_ROOT

WORKDIR $APP_ROOT/src/
ADD . $APP_ROOT/src/
RUN go mod download

ARG TARGETOS
ARG TARGETARCH
# The build context is the repository root, because go.mod lives there. The
# API's own Makefile is one level down and its recipes are relative to it.
RUN CGO_ENABLED=0 make -C api scorecard-webapp

# Multi-Stage production build
FROM golang:1.27.0@sha256:0ecdc2a9f6156af6451080bfe3d8382a662fcc4e209608c6f919e643453514c1 as deploy
# Retrieve the binary from the previous stage
COPY --from=builder /opt/app-root/src/api/scorecard-webapp /usr/local/bin/scorecard-webapp

# Set the binary as the entrypoint of the container
#
# --scheme=http is required, not a default. go-swagger derives the server's
# built-in listener default from the spec's `schemes`, which is `https`; with
# that default in force the binary refuses to start without --tls-certificate
# and --tls-key. TLS terminates at the load balancer and the container is
# reached over plain HTTP on the port below, so the listener is selected here
# rather than by changing the spec -- `schemes: [https]` is what the published
# document advertises and what generated clients default to, and both are
# correct.
ENTRYPOINT scorecard-webapp --scheme=http --host="0.0.0.0" --port=8080
EXPOSE 8080
