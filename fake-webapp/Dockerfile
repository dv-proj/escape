FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/fake-webapp .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/fake-webapp /fake-webapp
EXPOSE 8080
USER nonroot:nonroot
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 CMD ["/fake-webapp", "-healthcheck"]
ENTRYPOINT ["/fake-webapp"]
