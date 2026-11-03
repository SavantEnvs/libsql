CREATE TABLE t(a); INSERT INTO t VALUES(1); SELECT name, pageno FROM dbstat; SELECT opcode FROM bytecode('SELECT a FROM t') LIMIT 3;
