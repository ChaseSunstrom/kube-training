-- Schema + demo data for the capstone. Idempotent: safe to run again
-- (the Job may be retried, or re-applied after a database reset).
CREATE TABLE IF NOT EXISTS items (
  id    integer PRIMARY KEY,
  name  text    NOT NULL,
  price numeric(10,2) NOT NULL CHECK (price >= 0)
);

INSERT INTO items (id, name, price) VALUES
  (1, 'kubectl mug',        12.50),
  (2, 'YAML sticker pack',   4.00),
  (3, 'pod-shaped plushie', 19.99)
ON CONFLICT (id) DO NOTHING;

SELECT count(*) AS items FROM items;
