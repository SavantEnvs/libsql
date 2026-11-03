SELECT t1.id FROM vector_top_k('t1_idx', vector('[0,0,1,0]'), 2) i JOIN t1 ON t1.rowid = i.id;
