-- Create locked raw table in PROD me-west1
CREATE TABLE IF NOT EXISTS `raw_vault.raw_transactions` (
  transaction_id STRING,
  customer_id STRING,
  transaction_timestamp STRING,
  amount STRING,
  status STRING,
  raw_payload STRING,
  ingested_at TIMESTAMP
);

-- Truncate and seed test data
TRUNCATE TABLE `raw_vault.raw_transactions`;

INSERT INTO `raw_vault.raw_transactions` 
(transaction_id, customer_id, transaction_timestamp, amount, status, raw_payload, ingested_at)
VALUES
  -- 1. Standard valid completed transaction (regular value < 1000)
  ('TXN_1001', 'CUST_A1', '2026-10-01 10:15:30 UTC', '250.75', 'COMPLETED', '{"device": "web"}', CURRENT_TIMESTAMP()),
  
  -- 2. Standard valid completed high-value transaction (>= 1000)
  ('TXN_1002', 'CUST_B2', '2026-10-01 11:00:00 UTC', '1500.00', 'completed', '{"device": "ios"}', CURRENT_TIMESTAMP()),
  
  -- 3. Dirty strings: Whitespace in IDs, mixed case status, padded amount
  ('  TXN_1003  ', '  CUST_C3  ', '2026-10-01 12:30:45 UTC', '  89.99  ', '  peNDing  ', '{"device": "android"}', CURRENT_TIMESTAMP()),
  
  -- 4. Duplicate transaction IDs (TXN_1004) with different timestamps -> tests deduplication latest timestamp selection
  ('TXN_1004', 'CUST_D4', '2026-10-01 08:00:00 UTC', '400.00', 'PENDING', '{"attempt": 1}', CURRENT_TIMESTAMP()),
  ('TXN_1004', 'CUST_D4', '2026-10-01 09:30:00 UTC', '400.00', 'COMPLETED', '{"attempt": 2}', CURRENT_TIMESTAMP()),
  
  -- 5. Duplicate transaction IDs (TXN_1005) with high-value update
  ('TXN_1005', 'CUST_E5', '2026-10-02 14:00:00 UTC', '1200.50', 'failed', '{"reason": "timeout"}', CURRENT_TIMESTAMP()),
  ('TXN_1005', 'CUST_E5', '2026-10-02 14:05:00 UTC', '1200.50', 'COMPLETED', '{"reason": "retry_success"}', CURRENT_TIMESTAMP()),
  
  -- 6. Negative amount: Should be filtered out by staging condition (transaction_amount >= 0)
  ('TXN_INVALID_NEG', 'CUST_F6', '2026-10-02 15:00:00 UTC', '-50.00', 'COMPLETED', '{"flag": "error"}', CURRENT_TIMESTAMP()),
  
  -- 7. Blank / Empty transaction_id: Should be filtered out by staging condition
  ('   ', 'CUST_G7', '2026-10-02 16:00:00 UTC', '75.00', 'COMPLETED', '{"flag": "bad_id"}', CURRENT_TIMESTAMP()),
  (NULL, 'CUST_H8', '2026-10-02 16:30:00 UTC', '120.00', 'COMPLETED', '{"flag": "null_id"}', CURRENT_TIMESTAMP()),
  
  -- 8. Null status: Should be cleaned to 'UNKNOWN'
  ('TXN_1006', 'CUST_I9', '2026-10-03 10:00:00 UTC', '310.20', NULL, '{"source": "partner"}', CURRENT_TIMESTAMP()),
  
  -- 9. Null amount: Should be safely cast and coalesced to 0.0
  ('TXN_1007', 'CUST_J10', '2026-10-03 11:20:00 UTC', NULL, 'COMPLETED', '{"type": "complimentary"}', CURRENT_TIMESTAMP()),
  
  -- 10. Additional valid transaction across multiple dates for partition testing
  ('TXN_1008', 'CUST_A1', '2026-10-04 09:00:00 UTC', '2450.00', 'COMPLETED', '{"tier": "vip"}', CURRENT_TIMESTAMP()),
  ('TXN_1009', 'CUST_B2', '2026-10-05 18:45:00 UTC', '60.00', 'FAILED', '{"error": "insufficient_funds"}', CURRENT_TIMESTAMP());
