package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	_ "embed"
	"errors"
	"fmt"
	"net"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Amazon RDS CA bundle (https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem),
// compiled into the binary so TLS verification needs nothing from the filesystem.
//
//go:embed certs/rds-global-bundle.pem
var rdsCABundle []byte

type dbConfig struct {
	Host   string
	Port   string
	Name   string
	User   string
	Region string
}

func dbConfigFromEnv() (dbConfig, error) {
	var c dbConfig
	var errs []error
	for _, f := range []struct {
		dst *string
		key string
	}{
		{&c.Host, "DB_HOST"}, {&c.Port, "DB_PORT"}, {&c.Name, "DB_NAME"},
		{&c.User, "DB_USER"}, {&c.Region, "AWS_REGION"},
	} {
		v, err := mustEnv(f.key)
		*f.dst = v
		errs = append(errs, err)
	}
	return c, errors.Join(errs...)
}

// tlsConfig verifies the server certificate against the RDS CA and the hostname (verify-full).
func tlsConfig(host string) (*tls.Config, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(rdsCABundle) {
		return nil, errors.New("could not parse embedded RDS CA bundle")
	}
	return &tls.Config{RootCAs: pool, ServerName: host, MinVersion: tls.VersionTLS12}, nil
}

// poolConfig builds a pgx pool config with TLS enforced and no plaintext fallback.
func poolConfig(c dbConfig, user string) (*pgxpool.Config, error) {
	cfg, err := pgxpool.ParseConfig(fmt.Sprintf("host=%s port=%s dbname=%s user=%s", c.Host, c.Port, c.Name, user))
	if err != nil {
		return nil, err
	}
	tc, err := tlsConfig(c.Host)
	if err != nil {
		return nil, err
	}
	cfg.ConnConfig.TLSConfig = tc
	cfg.ConnConfig.Fallbacks = nil // never retry without TLS
	return cfg, nil
}

// newIAMPool returns a pool that logs in with a fresh RDS IAM auth token for every new
// connection. Tokens live 15 minutes, but they only matter at connect time, so
// minting one per connection means they never expire under us. Credentials come from
// the pod's IRSA role via the default AWS credential chain; there is no password anywhere.
func newIAMPool(ctx context.Context, c dbConfig, creds aws.CredentialsProvider) (*pgxpool.Pool, error) {
	cfg, err := poolConfig(c, c.User)
	if err != nil {
		return nil, err
	}
	endpoint := net.JoinHostPort(c.Host, c.Port)
	cfg.BeforeConnect = func(ctx context.Context, cc *pgx.ConnConfig) error {
		token, err := auth.BuildAuthToken(ctx, endpoint, c.Region, c.User, creds)
		if err != nil {
			return fmt.Errorf("build RDS IAM auth token: %w", err)
		}
		cc.Password = token
		return nil
	}
	cfg.MaxConns = 4
	// Every query (and connect) becomes a child span of the request span.
	cfg.ConnConfig.Tracer = otelpgx.NewTracer()
	// pgxpool connects lazily, so a paused Aurora doesn't block startup.
	return pgxpool.NewWithConfig(ctx, cfg)
}
