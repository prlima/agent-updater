BINARY  := github-agent
MAIN    := ./cmd/agent
LDFLAGS := -ldflags="-s -w"

.PHONY: build run test lint tidy install-tools

build:
	go build $(LDFLAGS) -o $(BINARY) $(MAIN)

run:
	GITHUB_WEBHOOK_SECRET=$${GITHUB_WEBHOOK_SECRET:?env var required} \
	go run $(MAIN) -config config.yaml

test:
	go test ./... -race -count=1

lint:
	golangci-lint run ./...

tidy:
	go mod tidy

# Cross-compile for Linux amd64 (deploy target)
build-linux:
	GOOS=linux GOARCH=amd64 go build $(LDFLAGS) -o $(BINARY)-linux-amd64 $(MAIN)

install-tools:
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
