/*
** libFuzzer harness: run fuzzed SQL against an in-memory libSQL database.
** Modelled on libsql-sqlite3/test/ossfuzz.c, but every bound is a deterministic
** count (VM-step callbacks, rows, heap) rather than a wall-clock deadline.
** Built twice from this one file: fuzz_sql (plain) and fuzz_vector (-DFUZZ_VECTOR,
** which first creates vector tables + a DiskANN index so the vector code is reachable).
*/
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "sqlite3.h"

typedef struct FuzzCtx {
  sqlite3 *db;
  unsigned nCb;       /* progress callbacks seen */
  unsigned execCnt;   /* rows still allowed */
} FuzzCtx;

#define MAX_PROGRESS_CALLBACKS 20000   /* x10 VM steps each */

static int progress_handler(void *pClientData){
  FuzzCtx *p = (FuzzCtx*)pClientData;
  return (++p->nCb)>=MAX_PROGRESS_CALLBACKS;
}

static int block_debug_pragmas(
  void *NotUsed, int eCode, const char *zArg1, const char *zArg2,
  const char *zArg3, const char *zArg4
){
  if( eCode==SQLITE_PRAGMA
   && zArg1
   && (sqlite3_strnicmp("vdbe_", zArg1, 5)==0
        || sqlite3_stricmp("parser_trace", zArg1)==0)
  ){
    return SQLITE_DENY;
  }
  return SQLITE_OK;
}

static int exec_handler(void *pClientData, int argc, char **argv, char **namev){
  FuzzCtx *p = (FuzzCtx*)pClientData;
  int i;
  if( argv ){
    for(i=0; i<argc; i++) sqlite3_free(sqlite3_mprintf("%s", argv[i]));
  }
  return (p->execCnt--)==0 || progress_handler(pClientData);
}

#ifdef FUZZ_VECTOR
static const char zSetup[] =
  "CREATE TABLE t1(id INTEGER PRIMARY KEY, v FLOAT32(4));"
  "CREATE INDEX t1_idx ON t1(libsql_vector_idx(v));"
  "INSERT INTO t1 VALUES(1,vector('[1,2,3,4]')),(2,vector('[4,3,2,1]')),"
  "(3,vector('[-1,0,1,0]')),(4,vector('[0.5,0.5,0.5,0.5]'));"
  "CREATE TABLE t2(name TEXT PRIMARY KEY, e FLOAT8(3));"
  "CREATE INDEX t2_idx ON t2(libsql_vector_idx(e, 'metric=l2', 'max_neighbors=4'));"
  "INSERT INTO t2 VALUES('a',vector8('[1,2,3]')),('b',vector8('[3,2,1]'));"
  "CREATE TABLE t3(x FLOAT64(2), y FLOAT1BIT(8), z FLOAT16(2), w FLOATB16(2));"
  "INSERT INTO t3 VALUES(vector64('[1,2]'),vector1bit('[1,0,1,0,1,0,1,0]'),"
  "vector16('[1,2]'),vectorb16('[1,2]'));";
#endif

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size){
  char *zErrMsg = 0;
  uint8_t uSelector;
  int rc;
  char *zSql;
  FuzzCtx cx;

  memset(&cx, 0, sizeof(cx));
  if( size<3 ) return -1;

  if( data[1]=='\n' ){
    uSelector = data[0];  data += 2; size -= 2;
  }else{
    uSelector = 0xfd;
  }

  if( sqlite3_initialize() ) return -1;
  rc = sqlite3_open_v2("fuzz.db", &cx.db,
           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY, 0);
  if( rc ) return -1;

  sqlite3_limit(cx.db, SQLITE_LIMIT_VDBE_OP, 25000);
  sqlite3_hard_heap_limit64(20000000);
  sqlite3_limit(cx.db, SQLITE_LIMIT_LENGTH, 50000);

#ifdef FUZZ_VECTOR
  sqlite3_exec(cx.db, zSetup, 0, 0, 0);
#endif
  sqlite3_progress_handler(cx.db, 10, progress_handler, (void*)&cx);

  sqlite3_db_config(cx.db, SQLITE_DBCONFIG_ENABLE_FKEY, uSelector&1, &rc);
  uSelector >>= 1;
  sqlite3_set_authorizer(cx.db, block_debug_pragmas, 0);
  cx.execCnt = uSelector + 1;

  zSql = sqlite3_mprintf("%.*s", (int)size, data);
  sqlite3_complete(zSql);
  sqlite3_exec(cx.db, zSql, exec_handler, (void*)&cx, &zErrMsg);

  sqlite3_free(zErrMsg);
  sqlite3_free(zSql);
  sqlite3_close(cx.db);
  return 0;
}
