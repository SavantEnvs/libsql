INSERT INTO t2 VALUES('c', vector8('[2,5,7]')); SELECT name FROM vector_top_k('t2_idx', vector8('[1,2,4]'), 2) i JOIN t2 ON t2.rowid=i.id;
