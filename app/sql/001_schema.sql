-- Applied by `hello-world migrate` on every deploy; must stay idempotent.
CREATE TABLE IF NOT EXISTS items (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
