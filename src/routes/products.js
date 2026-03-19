const express = require('express');
const { getDb } = require('../config/database');
const { authenticate, requireAdmin } = require('../middleware/auth');

const router = express.Router();

// GET /products — public, paginated
router.get('/', (req, res) => {
  const db = getDb();
  const page = Math.max(1, parseInt(req.query.page) || 1);
  const limit = Math.min(100, Math.max(1, parseInt(req.query.limit) || 20));
  const offset = (page - 1) * limit;

  const { count } = db.prepare('SELECT COUNT(*) as count FROM products').get();
  const products = db.prepare('SELECT * FROM products ORDER BY created_at DESC LIMIT ? OFFSET ?').all(limit, offset);

  res.json({
    products,
    pagination: { page, limit, total: count, pages: Math.ceil(count / limit) },
  });
});

// GET /products/:id — public
router.get('/:id', (req, res) => {
  const db = getDb();
  const product = db.prepare('SELECT * FROM products WHERE id = ?').get(req.params.id);
  if (!product) return res.status(404).json({ error: 'Product not found' });
  res.json({ product });
});

// POST /products — admin only
router.post('/', authenticate, requireAdmin, (req, res) => {
  const { name, description, price, stock, image_url } = req.body;

  if (!name || price == null) {
    return res.status(400).json({ error: 'name and price are required' });
  }
  if (!Number.isInteger(price) || price < 0) {
    return res.status(400).json({ error: 'price must be a non-negative integer (cents)' });
  }
  if (stock != null && (!Number.isInteger(stock) || stock < 0)) {
    return res.status(400).json({ error: 'stock must be a non-negative integer' });
  }

  const db = getDb();
  const result = db.prepare(
    'INSERT INTO products (name, description, price, stock, image_url) VALUES (?, ?, ?, ?, ?)'
  ).run(name, description ?? null, price, stock ?? 0, image_url ?? null);

  const product = db.prepare('SELECT * FROM products WHERE id = ?').get(result.lastInsertRowid);
  res.status(201).json({ product });
});

// PUT /products/:id — admin only
router.put('/:id', authenticate, requireAdmin, (req, res) => {
  const db = getDb();
  const product = db.prepare('SELECT * FROM products WHERE id = ?').get(req.params.id);
  if (!product) return res.status(404).json({ error: 'Product not found' });

  const { name, description, price, stock, image_url } = req.body;

  if (price != null && (!Number.isInteger(price) || price < 0)) {
    return res.status(400).json({ error: 'price must be a non-negative integer (cents)' });
  }
  if (stock != null && (!Number.isInteger(stock) || stock < 0)) {
    return res.status(400).json({ error: 'stock must be a non-negative integer' });
  }

  db.prepare(`
    UPDATE products SET
      name = COALESCE(?, name),
      description = COALESCE(?, description),
      price = COALESCE(?, price),
      stock = COALESCE(?, stock),
      image_url = COALESCE(?, image_url),
      updated_at = datetime('now')
    WHERE id = ?
  `).run(name ?? null, description ?? null, price ?? null, stock ?? null, image_url ?? null, req.params.id);

  const updated = db.prepare('SELECT * FROM products WHERE id = ?').get(req.params.id);
  res.json({ product: updated });
});

// DELETE /products/:id — admin only
router.delete('/:id', authenticate, requireAdmin, (req, res) => {
  const db = getDb();
  const product = db.prepare('SELECT id FROM products WHERE id = ?').get(req.params.id);
  if (!product) return res.status(404).json({ error: 'Product not found' });

  db.prepare('DELETE FROM products WHERE id = ?').run(req.params.id);
  res.json({ message: 'Product deleted' });
});

module.exports = router;
