-- Demo rows; ON CONFLICT keeps re-runs from duplicating them.
INSERT INTO items (name) VALUES
    ('Hello from Aurora Serverless v2'),
    ('Connected with an RDS IAM auth token'),
    ('Running on EKS (Graviton)'),
    ('Deployed by ArgoCD + helmfile')
ON CONFLICT (name) DO NOTHING;
