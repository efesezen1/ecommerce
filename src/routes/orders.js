const express = require('express');
const crypto = require('crypto');
const { getDb } = require('../config/database');
const { authenticate } = require('../middleware/auth');

const router = express.Router();

router.use(authenticate);

function mockPaymentIntent(amount) {
  return {
    id: 'pi_mock_' + crypto.randomBytes(12).toString('hex'),
    client_secret: 'mock_secret_' + crypto.randomBytes(16).toString('hex'),
    amount,
    currency: 'usd',
    status: 'requires_payment_method',
  };
}

// POST /orders/checkout — create order + mock PaymentIntent from cart
router.post('/checkout', (req, res) => {
  const db = getDb();
  const userId = req.user.id;

  const cartItems = db.prepare(`
    SELECT ci.quantity, p.id AS product_id, p.name, p.price, p.stock
    FROM cart_items ci
    JOIN products p ON p.id = ci.product_id
    WHERE ci.user_id = ?
  `).all(userId);

  if (cartItems.length === 0) {
    return res.status(400).json({ error: 'Cart is empty' });
  }

  for (const item of cartItems) {
    if (item.quantity > item.stock) {
      return res.status(400).json({
        error: `Insufficient stock for "${item.name}". Available: ${item.stock}`,
      });
    }
  }

  const total = cartItems.reduce((sum, item) => sum + item.price * item.quantity, 0);
  const paymentIntent = mockPaymentIntent(total);

  const createOrder = db.transaction(() => {
    const orderResult = db.prepare(
      'INSERT INTO orders (user_id, total, status, payment_intent_id, client_secret) VALUES (?, ?, ?, ?, ?)'
    ).run(userId, total, 'pending', paymentIntent.id, paymentIntent.client_secret);

    const orderId = orderResult.lastInsertRowid;

    const insertItem = db.prepare(
      'INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (?, ?, ?, ?)'
    );
    const decrementStock = db.prepare(
      'UPDATE products SET stock = stock - ? WHERE id = ?'
    );

    for (const item of cartItems) {
      insertItem.run(orderId, item.product_id, item.quantity, item.price);
      decrementStock.run(item.quantity, item.product_id);
    }

    db.prepare('DELETE FROM cart_items WHERE user_id = ?').run(userId);

    return orderId;
  });

  const orderId = createOrder();
  const order = db.prepare('SELECT * FROM orders WHERE id = ?').get(orderId);
  const items = db.prepare(`
    SELECT oi.*, p.name
    FROM order_items oi
    JOIN products p ON p.id = oi.product_id
    WHERE oi.order_id = ?
  `).all(orderId);

  res.status(201).json({
    order: { ...order, items },
    client_secret: paymentIntent.client_secret,
    _mock: 'Use POST /payments/:payment_intent_id/confirm or /fail to simulate payment',
  });
});

// GET /orders
router.get('/', (req, res) => {
  const db = getDb();
  const orders = db.prepare(
    'SELECT id, total, status, payment_intent_id, created_at FROM orders WHERE user_id = ? ORDER BY created_at DESC'
  ).all(req.user.id);
  res.json({ orders });
});

// GET /orders/:id
router.get('/:id', (req, res) => {
  const db = getDb();
  const order = db.prepare('SELECT * FROM orders WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.user.id);
  if (!order) return res.status(404).json({ error: 'Order not found' });

  const items = db.prepare(`
    SELECT oi.*, p.name
    FROM order_items oi
    JOIN products p ON p.id = oi.product_id
    WHERE oi.order_id = ?
  `).all(order.id);

  res.json({ order: { ...order, items } });
});

module.exports = router;
