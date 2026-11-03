REINDEX t1_idx; DROP INDEX t2_idx; CREATE INDEX t2_idx2 ON t2(libsql_vector_idx(e, 'metric=cosine')); SELECT * FROM libsql_vector_meta_shadow;
