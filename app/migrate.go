package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log/slog"
	"sort"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/jackc/pgx/v5"
)

//go:embed sql/*.sql
var sqlFiles embed.FS

// migrate runs as the RDS master user (password fetched from Secrets Manager at runtime,
// never stored anywhere) and makes the database ready for the app:
//  1. create the app's login role and grant rds_iam, so it can ONLY log in with IAM tokens
//  2. apply sql/*.sql in name order (schema + seed; every statement is idempotent)
//  3. grant the app role read access
//
// Safe to run on every deploy.
func migrate(ctx context.Context) error {
	dbc, err := dbConfigFromEnv()
	if err != nil {
		return err
	}
	masterUser, err := mustEnv("DB_MASTER_USER")
	if err != nil {
		return err
	}
	secretARN, err := mustEnv("DB_MASTER_SECRET_ARN")
	if err != nil {
		return err
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(dbc.Region))
	if err != nil {
		return err
	}
	password, err := masterPassword(ctx, secretsmanager.NewFromConfig(awsCfg), secretARN)
	if err != nil {
		return err
	}

	cfg, err := poolConfig(dbc, masterUser)
	if err != nil {
		return err
	}
	cfg.ConnConfig.Password = password
	// Aurora may still be starting (e.g. right after power.py up); give it time.
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	conn, err := pgx.ConnectConfig(ctx, cfg.ConnConfig)
	if err != nil {
		return fmt.Errorf("connect as master: %w", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()

	appRole := pgx.Identifier{dbc.User}.Sanitize()
	dbName := pgx.Identifier{dbc.Name}.Sanitize()

	steps := []string{
		// CREATE ROLE has no IF NOT EXISTS; check the catalog instead.
		fmt.Sprintf(`DO $$ BEGIN
			IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = %s) THEN
				CREATE ROLE %s LOGIN;
			END IF;
		END $$`, quoteLiteral(dbc.User), appRole),
		fmt.Sprintf(`GRANT rds_iam TO %s`, appRole),
	}

	names, err := fs.Glob(sqlFiles, "sql/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, n := range names {
		b, err := sqlFiles.ReadFile(n)
		if err != nil {
			return err
		}
		steps = append(steps, string(b))
	}

	steps = append(steps,
		fmt.Sprintf(`GRANT CONNECT ON DATABASE %s TO %s`, dbName, appRole),
		fmt.Sprintf(`GRANT USAGE ON SCHEMA public TO %s`, appRole),
		fmt.Sprintf(`GRANT SELECT ON ALL TABLES IN SCHEMA public TO %s`, appRole),
	)

	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	for i, s := range steps {
		if _, err := tx.Exec(ctx, s); err != nil {
			return fmt.Errorf("migration step %d: %w", i, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	slog.Info("migration complete", "steps", len(steps), "app_user", dbc.User)
	return nil
}

func masterPassword(ctx context.Context, sm *secretsmanager.Client, arn string) (string, error) {
	out, err := sm.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: &arn})
	if err != nil {
		return "", fmt.Errorf("get master secret: %w", err)
	}
	var s struct {
		Password string `json:"password"`
	}
	if out.SecretString == nil {
		return "", fmt.Errorf("master secret has no string value")
	}
	if err := json.Unmarshal([]byte(*out.SecretString), &s); err != nil || s.Password == "" {
		return "", fmt.Errorf("master secret is not RDS-managed JSON")
	}
	return s.Password, nil
}

// quoteLiteral quotes a string for use as an SQL literal.
func quoteLiteral(s string) string {
	out := []byte{'\''}
	for i := 0; i < len(s); i++ {
		if s[i] == '\'' {
			out = append(out, '\'')
		}
		out = append(out, s[i])
	}
	return string(append(out, '\''))
}
