const express = require('express');
const { getDb } = require('../config/database');
const { authenticate } = require('../middleware/auth');

const router = express.Router();

// All cart routes require authentication
router.use(authenticate);

function getCartWithProducts(db, userId) {
  const items = db.prepare(`
    SELECT ci.id, ci.quantity, ci.product_id,
           p.name, p.price, p.stock, p.image_url,
           (ci.quantity * p.price) AS subtotal
    FROM cart_items ci
    JOIN products p ON p.id = ci.product_id
    WHERE ci.user_id = ?
    ORDER BY ci.id
  `).all(userId);

  const total = items.reduce((sum, item) => sum + item.subtotal, 0);
  return { items, total };
}

// GET /cart
router.get('/', (req, res) => {
  const db = getDb();
  res.json(getCartWithProducts(db, req.user.id));
});

// POST /cart/items — add or increment item
router.post('/items', (req, res) => {
  const { product_id, quantity = 1 } = req.body;

  if (!product_id) {
    return res.status(400).json({ error: 'product_id is required' });
  }
  if (!Number.isInteger(quantity) || quantity < 1) {
    return res.status(400).json({ error: 'quantity must be a positive integer' });
  }

  const db = getDb();
  const product = db.prepare('SELECT * FROM products WHERE id = ?').get(product_id);
  if (!product) return res.status(404).json({ error: 'Product not found' });

  // Upsert: if item exists, add to quantity
  db.prepare(`
    INSERT INTO cart_items (user_id, product_id, quantity)
    VALUES (?, ?, ?)
    ON CONFLICT(user_id, product_id) DO UPDATE SET quantity = quantity + excluded.quantity
  `).run(req.user.id, product_id, quantity);

  res.status(201).json(getCartWithProducts(db, req.user.id));
});

// PUT /cart/items/:productId — set exact quantity
router.put('/items/:productId', (req, res) => {
  const { quantity } = req.body;

  if (!Number.isInteger(quantity) || quantity < 1) {
    return res.status(400).json({ error: 'quantity must be a positive integer' });
  }

  const db = getDb();
  const item = db.prepare('SELECT id FROM cart_items WHERE user_id = ? AND product_id = ?')
    .get(req.user.id, req.params.productId);
  if (!item) return res.status(404).json({ error: 'Item not in cart' });

  db.prepare('UPDATE cart_items SET quantity = ? WHERE user_id = ? AND product_id = ?')
    .run(quantity, req.user.id, req.params.productId);

  res.json(getCartWithProducts(db, req.user.id));
});

// DELETE /cart/items/:productId — remove single item
router.delete('/items/:productId', (req, res) => {
  const db = getDb();
  const result = db.prepare('DELETE FROM cart_items WHERE user_id = ? AND product_id = ?')
    .run(req.user.id, req.params.productId);

  if (result.changes === 0) return res.status(404).json({ error: 'Item not in cart' });

  res.json(getCartWithProducts(db, req.user.id));
});

// DELETE /cart — clear entire cart
router.delete('/', (req, res) => {
  const db = getDb();
  db.prepare('DELETE FROM cart_items WHERE user_id = ?').run(req.user.id);
  res.json({ items: [], total: 0 });
});

module.exports = router;
