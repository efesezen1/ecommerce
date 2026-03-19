const express = require('express');
const { getDb } = require('../config/database');

const router = express.Router();

// Mock payment gateway — simulates Stripe-like events locally.
// POST /payments/:paymentIntentId/confirm — simulate successful payment
router.post('/:paymentIntentId/confirm', (req, res) => {
  const db = getDb();
  const order = db.prepare('SELECT * FROM orders WHERE payment_intent_id = ?')
    .get(req.params.paymentIntentId);

  if (!order) return res.status(404).json({ error: 'No order found for this payment intent' });
  if (order.status !== 'pending') {
    return res.status(409).json({ error: `Order is already "${order.status}"` });
  }

  db.prepare("UPDATE orders SET status = 'paid' WHERE payment_intent_id = ?")
    .run(req.params.paymentIntentId);

  res.json({ payment_intent_id: req.params.paymentIntentId, status: 'paid' });
});

// POST /payments/:paymentIntentId/fail — simulate failed payment
router.post('/:paymentIntentId/fail', (req, res) => {
  const db = getDb();
  const order = db.prepare('SELECT * FROM orders WHERE payment_intent_id = ?')
    .get(req.params.paymentIntentId);

  if (!order) return res.status(404).json({ error: 'No order found for this payment intent' });
  if (order.status !== 'pending') {
    return res.status(409).json({ error: `Order is already "${order.status}"` });
  }

  db.prepare("UPDATE orders SET status = 'failed' WHERE payment_intent_id = ?")
    .run(req.params.paymentIntentId);

  res.json({ payment_intent_id: req.params.paymentIntentId, status: 'failed' });
});

module.exports = router;
