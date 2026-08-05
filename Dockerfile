# Copyright 2026 The uwu-tools Authors.
# SPDX-License-Identifier: Apache-2.0

# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/scorecard-api ./cmd/scorecard-api

FROM alpine:3.21

RUN apk add --no-cache ca-certificates && \
    adduser -D -u 10001 scorecard && \
    mkdir -p /data && chown scorecard:scorecard /data

COPY --from=builder /out/scorecard-api /usr/local/bin/scorecard-api

USER scorecard
VOLUME /data
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/scorecard-api"]
