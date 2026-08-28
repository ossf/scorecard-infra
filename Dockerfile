# Copyright 2026 OpenSSF Scorecard Authors.
# SPDX-License-Identifier: Apache-2.0

# syntax=docker/dockerfile:1

FROM golang:1.27-alpine@sha256:4c9fe60190a2a3350ddc51de80d0224b8a6698d12bdfc999fee45ea9d6c46dbc AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/scorecard-api ./cmd/scorecard-api

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add --no-cache ca-certificates && \
    adduser -D -u 10001 scorecard && \
    mkdir -p /data && chown scorecard:scorecard /data

COPY --from=builder /out/scorecard-api /usr/local/bin/scorecard-api

USER scorecard
VOLUME /data
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/scorecard-api"]
