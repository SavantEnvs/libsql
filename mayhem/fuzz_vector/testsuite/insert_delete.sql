INSERT INTO t1 VALUES(10, vector('[9,9,9,9]')); DELETE FROM t1 WHERE id=1; UPDATE t1 SET v=vector('[2,2,2,2]') WHERE id=2; SELECT id FROM vector_top_k('t1_idx', vector('[2,2,2,2]'), 5);
