BEGIN;

ALTER TABLE products ADD COLUMN IF NOT EXISTS sku TEXT;
UPDATE products SET sku = 'SKU-' || lpad(id::text, 5, '0') WHERE sku IS NULL;
ALTER TABLE products ALTER COLUMN sku SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS products_sku_idx ON products (sku);

COMMIT;
