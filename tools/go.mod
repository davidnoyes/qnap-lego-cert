// Not built. This module only records the lego version that LegoCert ships, so that
// Dependabot (gomod) can propose updates. scripts/fetch-lego.sh reads the version
// from the require line below and downloads that release's binaries.
module github.com/davidnoyes/qnap-lego-cert/tools

go 1.26.0

require github.com/go-acme/lego/v5 v5.6.0

require (
	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
	github.com/go-jose/go-jose/v4 v4.1.6 // indirect
	github.com/miekg/dns v1.1.73 // indirect
	golang.org/x/crypto v0.58.0 // indirect
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	software.sslmate.com/src/go-pkcs12 v0.7.4 // indirect
)
