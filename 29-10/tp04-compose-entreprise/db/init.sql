-- execute une seule fois, a la creation du volume pgdata
CREATE TABLE IF NOT EXISTS products (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  price NUMERIC(10, 2) NOT NULL,
  stock INT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS orders (
  id SERIAL PRIMARY KEY,
  product_id INT NOT NULL REFERENCES products(id),
  quantity INT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS orders_status_idx ON orders (status);

INSERT INTO products (name, price, stock) VALUES
  ('Clavier mécanique', 89.90, 12),
  ('Écran 27"', 249.00, 4),
  ('Souris sans fil', 29.50, 40),
  ('Casque audio', 119.00, 8),
  ('Webcam HD', 59.90, 15);
