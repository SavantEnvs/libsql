CREATE VIRTUAL TABLE f USING fts5(a,b); INSERT INTO f VALUES('hello world','foo bar'),('goodbye','world'); SELECT rowid, highlight(f,0,'[',']') FROM f WHERE f MATCH 'world';
